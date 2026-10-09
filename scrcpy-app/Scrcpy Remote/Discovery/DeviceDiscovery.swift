//
//  DeviceDiscovery.swift
//  Scrcpy Remote
//
//  「发现设备」的统一数据源（Devices 页的扫描面板用）：
//    · 局域网组：扫网段 → 批量识别（型号 + 序列号后4位）→ 认完立即断开
//    · frpc 在线组：拉 frps 管理接口（webServer）的在线 proxy 名单
//    · ★ tailnet 组（2026-10-09 补）：内置 tsnet 的 netmap 里所有 `phone-*` 节点 ——
//      **不依赖家宽 v6 / frps 名单 / 已保存会话**（公司网等够不到家里的场景照样能列出来）
//    · 合并：同一台（型号 + 序列号后4位）多边都出现时合成一行，
//      连接时由既有的三级连接逻辑自动「局域网 → frpc(P2P) → 中转」选路。
//
//  ★ 识别读的是 ro.serialno / ro.product.model，和被控端部署脚本
//    （deploy-frpc.py 的 phone-<型号>-<序列号后4位>）同源，所以两边能对上。
//
//  ★ 速度设计（2026-10-07 用户反馈"局域网好慢"后重做）：
//    ① 身份结果**持久缓存**（host → 型号+后缀）—— 识别过的设备下次秒出
//    ② 未识别的设备：**并行发起 adb connect**（握手最慢，并发摊掉），
//       等状态沉淀（offline/authorizing → device）后**串行读身份**（此时很快）
//    ③ 型号和序列号一次 shell 全拿（`getprop A; getprop B`），省一半往返
//

import Foundation

struct DiscoveredDevice: Identifiable {
    let id: String              // "<型号>-<序列号后4位>"，如 COR-AL10-1911（合并时按大小写不敏感比）
    let model: String           // COR-AL10
    let suffix: String          // 1911
    var lanHost: String?        // 局域网地址（nil = 不在局域网）
    var frpProxyName: String?   // frpc 在线时的 proxy 名（nil = 没挂 frpc）
    var relayPort: Int?         // frpc 的 -tcp remotePort（6000~6099；nil = 不知道）
    /// 端到端实测：serverAddr:relayPort 真连一次通过（= 控制端→frps→frpc→adbd 整条链活）。
    /// 「中转」「打洞」两盏灯的判据 —— 亮灯 = 连接前就已实测能连（用户点名的标准）。
    var relayReachable: Bool = false
    var tailnetOnline: Bool = false  // tailnet 探针结果（真拨 5555 一次通过）
    /// tailnet 主机名（= proxy 名小写，phone-<型号>-<后4位>；nil = netmap 里没有这台）。
    /// 「设备列表的第三个发现源」靠它认人（见 mergeTailnetPeers）。
    var tailnetName: String? = nil
    /// tailnet IPv4（100.x）—— 点选直连时直接预填「Tailscale」方式用。
    var tailnetHost: String? = nil

    var displayName: String { "\(model) · \(suffix)" }
    var canLan: Bool { lanHost != nil }
    var canFrp: Bool { frpProxyName != nil }
    var canRelay: Bool { frpProxyName != nil && relayPort != nil }
}

@MainActor
final class DeviceDiscovery: ObservableObject {

    @Published var devices: [DiscoveredDevice] = []
    @Published var phase: String = ""
    @Published var frpError: String? = nil
    @Published private(set) var running = false

    /// 用户给设备起的名字：deviceId（型号-序列号后4位）→ 自定义名。
    /// 持久保存；连接时用作会话名。清空输入 = 恢复默认显示名。
    @Published private(set) var customNames: [String: String] = [:]

    private static let customNamesKey = "settings.discovery.device_names"

    init() {
        customNames = UserDefaults.standard.dictionary(forKey: Self.customNamesKey) as? [String: String] ?? [:]
        // ★ 发现过的设备持久化回填（用户定稿 2026-10-09）：扫描到的设备自动进面板、
        //   关掉 App 也还在；之后的扫描只更新这台设备的四盏灯（扫到就绿、没扫到就灰）。
        //   灯先全灰，本轮扫描/探针点亮。
        devices = Self.loadKnownDevices()
    }

    /// 显示用名字：用户起过名就用它，否则「型号 · 后4位」
    func name(for device: DiscoveredDevice) -> String {
        if let k = customKey(for: device.id), let custom = customNames[k], !custom.isEmpty {
            return custom
        }
        return device.displayName
    }

    /// 重命名输入框的回显（大小写不敏感，见 customKey）
    func customName(for device: DiscoveredDevice) -> String? {
        customKey(for: device.id).flatMap { customNames[$0] }
    }

    /// 大小写不敏感地找自定义名的存储键 —— tailnet 来源的 id 是小写
    /// （cor-al10-1911），LAN/frps 来源保留 getprop 原大小写（COR-AL10-1911）。
    private func customKey(for id: String) -> String? {
        if customNames[id] != nil { return id }
        return customNames.keys.first { $0.caseInsensitiveCompare(id) == .orderedSame }
    }

    /// 重命名（空字符串 = 恢复默认）
    func rename(_ device: DiscoveredDevice, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let k = customKey(for: device.id) { customNames.removeValue(forKey: k) }
        if !trimmed.isEmpty { customNames[device.id] = trimmed }
        UserDefaults.standard.set(customNames, forKey: Self.customNamesKey)
    }

    /// 忘记一台设备：从面板和持久化记录里都删掉（设备本身不受影响）。
    /// 有保存会话的行删的是会话；这个删的是「扫描发现」留下的那条记录。
    func forget(_ device: DiscoveredDevice) {
        devices.removeAll { $0.id.caseInsensitiveCompare(device.id) == .orderedSame }
        if let k = customKey(for: device.id) { customNames.removeValue(forKey: k) }
        UserDefaults.standard.set(customNames, forKey: Self.customNamesKey)
        persistKnownDevices()
    }

    // MARK: - 已知设备持久化（扫描发现 → 自动保存在面板）

    /// 发现过的设备持久化 —— 关掉 App 再打开面板里还在（用户定稿 2026-10-09：
    /// 「扫描到的设备自动保存在面板，之后扫描只更新这台设备的四盏灯」）。
    ///
    /// 存什么：**只存设备身份** —— 型号 + 序列号后4位（id/model/suffix），
    /// 外加 tailnet 主机名（如果见过，它也是身份）。这样够了：
    /// **IP / 端口一律不存** —— 它们会变，由每次的实时扫描 / frps 名单 / netmap 刷新
    /// （用户点名：具体 ip 和端口要根据实时扫描结果变化）。
    private static let knownDevicesKey = "settings.discovery.known_devices"

    private static func loadKnownDevices() -> [DiscoveredDevice] {
        guard let raw = UserDefaults.standard.array(forKey: knownDevicesKey) as? [[String: Any]] else {
            return []
        }
        return raw.compactMap { d in
            guard let id = d["id"] as? String,
                  let model = d["model"] as? String,
                  let suffix = d["suffix"] as? String else { return nil }
            var dev = DiscoveredDevice(id: id, model: model, suffix: suffix,
                                       lanHost: nil, frpProxyName: nil)
            dev.tailnetName = d["tailnetName"] as? String
            return dev
        }
    }

    private func persistKnownDevices() {
        let raw: [[String: Any]] = devices.map { d in
            var m: [String: Any] = ["id": d.id, "model": d.model, "suffix": d.suffix]
            if let tn = d.tailnetName { m["tailnetName"] = tn }
            return m
        }
        UserDefaults.standard.set(raw, forKey: Self.knownDevicesKey)
    }

    /// 跑一轮完整发现：先 frpc 名单（快），再局域网扫描 + 批量识别（逐台出现）。
    func run() async {
        guard !running else { return }   // 已在跑（预热/上一次下拉刷新）就复用那一轮
        running = true
        // ★ 已知设备先上屏（持久化的）—— 扫描只更新灯，绝不把没扫到的设备从面板抹掉
        //   （用户定稿 2026-10-09：「扫描到就绿、没有就灰」）。
        devices = Self.loadKnownDevices()
        frpError = nil

        phase = "Getting frpc online devices…"
        let (frpDevices, frpErr) = await Self.fetchFrpOnline()
        frpError = frpErr
        merge(frpDevices)

        // ★ tailnet 也是发现源（netmap，走 IPv4/DERP）—— 早并一次，够不到家里的网络里
        //   列表也能立刻有设备；末轮 refreshTailnetStatus 还会再并一次（幂等）。
        await mergeTailnetPeers()

        phase = "Scanning LAN…"
        // ① Bonjour 快路径：开着无线调试/adb-tcp 的手机在局域网广播，秒级出结果先上屏
        let bonjour = await LanDiscovery.discoverBonjour()
        await identifyAndMerge(hosts: bonjour.map { $0.host })

        // ② 全量扫描兜底（走共享扫描，复用预热任务/最近缓存）—— 直接调 LanDiscovery.discover()
        //   会和启动预热扫描并发跑两份 253 地址扫描，这就是 2026-10-07 实测的卡顿来源。
        let candidates = await SessionNetworking.shared.sharedLanCandidates()
        await identifyAndMerge(hosts: candidates.map { $0.host })

        phase = devices.isEmpty ? "No devices found" : "Done"
        running = false
        // 收尾把两类探针跑一遍（首页的灯尽快出结果）
        await refreshRelayReachability()
        await refreshTailnetStatus()
        // 本轮新认到的设备（LAN 识别 / frps 名单 / tailnet netmap）全部落盘
        persistKnownDevices()
    }

    /// 端到端「中转可达」实测（用户点名的标准：亮灯 = 连接前就已实测能连）。
    ///
    /// 真连一次 `serverAddr:relayPort` —— 这条 TCP 走的就是 adb 会话的原路径：
    /// 控制端 → frps → 该手机的 frpc → 手机 adbd:5555。
    /// 连得上 ⟺ 整条链活（frps 在、frpc 在、adbd 在）；连不上 → 灯灰。
    ///
    /// 「打洞」灯用同一判据：打洞成不成只有真连的时候才知道（frp 内部失败会自动回落
    /// 中转），但「端到端活」是打洞有意义的前提 —— 所以这盏灯绿 = 一定能连上
    /// （最差走 frp 内建回落）。
    func refreshRelayReachability() async {
        let settings = FrpSettings.load()
        let serverAddr = settings.serverAddr.trimmingCharacters(in: .whitespaces)

        guard !serverAddr.isEmpty else {
            for i in devices.indices { devices[i].relayReachable = false }
            return
        }

        let targets: [(Int, String, UInt16)] = devices.enumerated().compactMap { (i, d) in
            guard let rp = d.relayPort, let port = UInt16(exactly: rp) else { return nil }
            return (i, serverAddr, port)
        }
        guard !targets.isEmpty else {
            for i in devices.indices { devices[i].relayReachable = false }
            return
        }

        let results = await withTaskGroup(of: (Int, Bool).self) { group -> [(Int, Bool)] in
            for (i, host, port) in targets {
                group.addTask {
                    let ok = await withCheckedContinuation { cont in
                        DispatchQueue.global(qos: .utility).async {
                            cont.resume(returning: LanDiscovery.measureRoundTrip(host: host, port: port, timeout: 1.2) != nil)
                        }
                    }
                    return (i, ok)
                }
            }
            var out: [(Int, Bool)] = []
            for await r in group { out.append(r) }
            return out
        }

        for i in devices.indices { devices[i].relayReachable = false }
        for (i, ok) in results where ok && i < devices.count {
            devices[i].relayReachable = true
        }
    }

    /// 对一批 host 做识别并上屏（走身份缓存：认过的设备秒出，没认过的并行握手 + 串行读序列号）。
    private func identifyAndMerge(hosts: [String]) async {
        guard !hosts.isEmpty else { return }
        let cache = Self.loadIdentityCache()
        var needIdentify: [String] = []
        var newCache = cache

        for host in hosts {
            if let cached = cache[host] {
                merge([DiscoveredDevice(id: "\(cached.0)-\(cached.1)",
                                        model: cached.0,
                                        suffix: cached.1,
                                        lanHost: host,
                                        frpProxyName: nil)])
            } else {
                needIdentify.append(host)
            }
        }

        guard !needIdentify.isEmpty else { return }
        phase = "Identifying devices…"
        let identified = await Self.identifyMany(hosts: needIdentify)
        for (host, info) in identified {
            newCache[host] = (info.model, info.suffix)
            merge([DiscoveredDevice(id: "\(info.model)-\(info.suffix)",
                                    model: info.model,
                                    suffix: info.suffix,
                                    lanHost: host,
                                    frpProxyName: nil)])
        }
        Self.saveIdentityCache(newCache)
    }

    // MARK: - 实时轻量刷新（首页轮询用）

    /// 上一次轻量刷新时在不在 WiFi —— 用来捕捉「回到 WiFi」这个时刻补一次全量扫描
    private var lastOnWiFi: Bool?

    /// 轻量刷新：只重拉 frps 名单 + 探 tailnet + 探已知局域网地址的存活。
    /// **不跑全子网扫描** —— 那玩意耗电，还会把 adb 设备表弄脏（实测 push 会失败）。
    func refreshLightweight() async {
        guard !running else { return }   // 全量扫描进行中就跳过这轮

        // WiFi 切换捕捉（用户点名要求的语义）：
        //   · 不在 WiFi（蜂窝）→ 局域网这条路根本不存在，一个包都不发（见 refreshLanLiveness）
        //   · 刚回到 WiFi → 补一轮全量扫描，把局域网设备重新捞出来
        let nowOnWiFi = LanDiscovery.isOnWiFi()
        let cameBackToWiFi = (lastOnWiFi == false) && nowOnWiFi
        lastOnWiFi = nowOnWiFi
        if cameBackToWiFi {
            print("[DeviceDiscovery] 回到 WiFi —— 补一轮全量扫描")
            await run()
        }

        // 1) frps 名单（xtcp + tcp 两把，1KB 级请求，可以高频）
        let (frpDevices, frpErr) = await Self.fetchFrpOnline()
        frpError = frpErr
        merge(frpDevices)

        // 2) 控制端可达性门控（用户点名的判据）：
        //    拉 frps 名单 = 正在连「家里的 v6」。拉到了，说明**控制端这条路通**，
        //    打洞/中转的灯才可信；拉不到（或没配账号拉不了），一律灰 —— 不装可用。
        if frpErr != nil {
            for i in devices.indices {
                devices[i].frpProxyName = nil
                devices[i].relayPort = nil
            }
        } else {
            // 已经从 frps 掉线的设备：清掉 frp 标记（打洞/中转灯变灰）
            // ★ id 比较必须大小写不敏感（和 merge 同款坑）：设备行 id 可能来自 tailnet
            //   发现源（全小写 cor-al10-1911），而 frps 名单保留 getprop 原大小写
            //   （COR-AL10-1911）—— 精确匹配会把在线设备误判成掉线，8 秒一轮里
            //   中转/打洞灯就会「手动刷新亮、自动刷新灭」地闪（用户 2026-10-09 实测）。
            let onlineIds = Set(frpDevices.map { $0.id.lowercased() })
            for i in devices.indices {
                if devices[i].frpProxyName != nil && !onlineIds.contains(devices[i].id.lowercased()) {
                    devices[i].frpProxyName = nil
                    devices[i].relayPort = nil
                }
            }
        }

        // 3) 端到端「中转可达」实测（中转/打洞两盏灯的判据）
        await refreshRelayReachability()

        // 4) tailnet 探针
        await refreshTailnetStatus()

        // 4) 已知局域网地址的存活探测（每台一个 0.6s 往返；几台就几个包）
        await refreshLanLiveness()

        // 本轮 tailnet 并进来的新设备落盘（幂等；灯的状态不存，只存身份）
        persistKnownDevices()
    }

    /// 对已知的局域网地址做轻量存活探测：死掉的把 lanHost 清成 nil（灯变灰）。
    ///
    /// ★ 没开 WiFi（蜂窝）就直接全灰 —— 用户点名要求：这时候局域网这条路本来
    ///   就不存在，探测只会白等一串超时，一个包都不该发。
    private func refreshLanLiveness() async {
        guard LanDiscovery.isOnWiFi() else {
            for i in devices.indices where devices[i].lanHost != nil {
                devices[i].lanHost = nil
            }
            return
        }

        let targets: [(Int, String)] = devices.enumerated().compactMap { (i, d) in
            guard let h = d.lanHost else { return nil }
            return (i, h)
        }
        guard !targets.isEmpty else { return }

        let results = await withTaskGroup(of: (Int, Bool).self) { group -> [(Int, Bool)] in
            for (i, host) in targets {
                group.addTask {
                    let ok = await withCheckedContinuation { cont in
                        DispatchQueue.global(qos: .utility).async {
                            cont.resume(returning: LanDiscovery.measureRoundTrip(host: host, port: 5555, timeout: 0.6) != nil)
                        }
                    }
                    return (i, ok)
                }
            }
            var out: [(Int, Bool)] = []
            for await r in group { out.append(r) }
            return out
        }

        for (i, ok) in results where i < devices.count {
            if !ok { devices[i].lanHost = nil }
        }
    }

    /// 视图喂进来的额外设备身份（已保存会话的 proxy 名）——
    /// TS 探测的候选集 = 发现列表 ∪ 这个。**不依赖 frps 名单**：
    /// 公司网等够不到家里 v6 的场景 frps 必空，但 tailnet（走 IPv4/DERP）照样能用。
    var extraProxyNames: [String] = []

    /// tailnet 探针结果（按 proxy 名小写存）——「已保存会话」行取灯用
    @Published private(set) var sessionTailnetOnline: [String: Bool] = [:]

    /// 对候选设备探一遍 tailnet（首页 TS 灯）+ 把 netmap 里的节点并进列表。
    ///
    /// 判据（用户定稿）：**只看被控端在不在线** —— 被控端 = FrpcApp（或脚本版）里内置的
    /// relay tsnet，名字约定：proxy 名全小写（TsnetRunner：`TS_HOSTNAME = proxyName.lowercase()`），
    /// 拼上本节点 MagicDNS 后缀就是它的全名，真拨一次 TCP 才算在线。
    /// 控制端那半（App 内置 tsnet）不算条件 —— 选 Tailscale 连接时自然会起；
    /// 这里保证它活着只是为了**探测本身**能跑（用户态、不占 VPN 槽，代价为零）。
    func refreshTailnetStatus() async {
        // ★ 本端 tsnet 没起：**每轮都尝试拉**（ensureConnected 幂等）—— 之前「只试一次 +
        //   睡 3 秒」的写法在冷启动首次连接慢时会永久失联（用户实测：TS 一直不亮）。
        //   本轮先全灰，8 秒后的下一轮再探。
        if !TailscaleManager.shared.isStarted() {
            if TailscaleManager.shared.isConfigurationValid() {
                print("[DeviceDiscovery] 内置 tsnet 未启动 —— 尝试拉起（探测前提，非灯的条件）")
                _ = TailscaleManager.shared.ensureConnected()
            } else {
                print("[DeviceDiscovery] 内置 tsnet 未配置（设置 → Tailscale）—— TS 灯保持灰")
            }
            for i in devices.indices { devices[i].tailnetOnline = false }
            return
        }

        // ★ tailnet 本身也是发现源：把 netmap 里的 `phone-*` 节点并进列表（幂等，每轮跑）。
        //   这一步不依赖 suffix —— 节点的 100.x 是现成的；够不到家里的网络里就靠它出行。
        await mergeTailnetPeers()

        guard let suffix = TailscaleManager.shared.magicDNSSuffix() else {
            print("[DeviceDiscovery] TS 探针：拿不到 MagicDNS 后缀，本轮全灰")
            for i in devices.indices { devices[i].tailnetOnline = false }
            return
        }

        // 探针目标：key = 小写身份名（= tailnet 主机名 = proxy 名小写）→ 真正拨的地址。
        //   · tailnet 来源的行：直接拨 100.x（省一次名字解析，最稳）
        //   · frps 来源的行：拼 MagicDNS 全名拨（本端状态里能解析成 100.x，见 TsnetProbe）
        //   · 已保存会话的身份：不在上面的补进来
        var dialHostByKey: [String: String] = [:]
        for dev in devices {
            if let n = dev.tailnetName, !n.isEmpty {
                dialHostByKey[n] = dev.tailnetHost ?? "\(n).\(suffix)"
            } else if let p = dev.frpProxyName, !p.isEmpty {
                let k = p.lowercased()
                dialHostByKey[k] = "\(k).\(suffix)"
            }
        }
        for p in extraProxyNames {
            let t = p.trimmingCharacters(in: .whitespaces).lowercased()
            if !t.isEmpty, dialHostByKey[t] == nil { dialHostByKey[t] = "\(t).\(suffix)" }
        }
        guard !dialHostByKey.isEmpty else { return }

        let targets = Array(dialHostByKey)
        let results = await withTaskGroup(of: (String, Bool).self) { group -> [(String, Bool)] in
            for (key, host) in targets {
                group.addTask {
                    let ok = await withCheckedContinuation { cont in
                        DispatchQueue.global(qos: .utility).async {
                            cont.resume(returning: TailscaleManager.shared.probe(host: host))
                        }
                    }
                    return (key, ok)
                }
            }
            var out: [(String, Bool)] = []
            for await r in group { out.append(r) }
            return out
        }

        var onlineByName: [String: Bool] = [:]
        var hits = 0
        for (name, ok) in results {
            onlineByName[name] = ok
            if ok { hits += 1 }
        }
        sessionTailnetOnline = onlineByName
        for i in devices.indices {
            let key = devices[i].tailnetName ?? devices[i].frpProxyName?.lowercased()
            if let k = key, let ok = onlineByName[k] {
                devices[i].tailnetOnline = ok
            }
        }
        print("[DeviceDiscovery] TS 探针：\(targets.count) 台，在线 \(hits) 台")
    }

    /// 把 tailnet netmap 里的被控手机并进设备列表 —— 「扫描」的第三个发现源。
    ///
    /// 数据源 = 内置 tsnet 的节点表（控制面推下来，走 IPv4/DERP）：**不依赖家宽公网 v6、
    /// 不依赖 frps 名单、不依赖已保存会话** —— 用户 2026-10-09 实测点名的场景
    /// （公司网无 v6 + 清空已保存设备，纯靠扫描也要能列出 tailnet 里的手机）。
    ///
    /// 命名约定：被控手机 relay 的 tailnet 主机名 = proxy 名小写（phone-<型号>-<后4位>），
    /// 与 frps 名单/LAN 识别的身份（型号 + 后4位）同源，按 id 合并成一行；
    /// 别的 tailnet 成员（本机、家里电脑等）不带 phone- 前缀，不进列表。
    private func mergeTailnetPeers() async {
        let peers: [TailscaleManager.TailnetPeer] = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(returning: TailscaleManager.shared.listPeers())
            }
        }
        guard !peers.isEmpty else { return }

        var incoming: [DiscoveredDevice] = []
        for peer in peers {
            let name = peer.hostName.lowercased()
            guard name.hasPrefix("phone-") else { continue }
            let parts = name.split(separator: "-").map(String.init)
            guard parts.count >= 3, let suffix = parts.last, suffix.count >= 3 else { continue }
            let model = parts[1..<(parts.count - 1)].joined(separator: "-")
            var d = DiscoveredDevice(id: "\(model)-\(suffix)",
                                     model: model.uppercased(),
                                     suffix: suffix.uppercased(),
                                     lanHost: nil,
                                     frpProxyName: nil)
            d.tailnetName = name
            if !peer.ip.isEmpty { d.tailnetHost = peer.ip }
            d.tailnetOnline = peer.online   // 先给 netmap 标记；本轮探针结果随后覆盖
            incoming.append(d)
        }
        merge(incoming)
    }

    // MARK: - 合并

    /// 三路来源（LAN 识别 / frps 名单 / tailnet netmap）按身份合并成一行。
    /// ★ id 比较**大小写不敏感**：tailnet 主机名是 proxy 名全小写（phone-cor-al10-1911），
    ///   而 LAN 识别/frps 名单保留 getprop 的原始大小写（COR-AL10-1911）—— 不这样会同机两行。
    private func merge(_ incoming: [DiscoveredDevice]) {
        for device in incoming {
            if let index = devices.firstIndex(where: { $0.id.caseInsensitiveCompare(device.id) == .orderedSame }) {
                if let lan = device.lanHost { devices[index].lanHost = lan }
                if let frp = device.frpProxyName { devices[index].frpProxyName = frp }
                if let rp = device.relayPort { devices[index].relayPort = rp }
                if let tn = device.tailnetName { devices[index].tailnetName = tn }
                if let th = device.tailnetHost { devices[index].tailnetHost = th }
            } else {
                devices.append(device)
            }
        }
    }

    // MARK: - 身份缓存（host -> 型号、序列号后4位）

    private static let identityCacheKey = "settings.discovery.lan_identity_cache"

    private static func loadIdentityCache() -> [String: (String, String)] {
        guard let raw = UserDefaults.standard.dictionary(forKey: identityCacheKey) as? [String: [String]] else {
            return [:]
        }
        var out: [String: (String, String)] = [:]
        for (host, pair) in raw where pair.count == 2 {
            out[host] = (pair[0], pair[1])
        }
        return out
    }

    private static func saveIdentityCache(_ cache: [String: (String, String)]) {
        var raw: [String: [String]] = [:]
        for (host, pair) in cache {
            raw[host] = [pair.0, pair.1]
        }
        UserDefaults.standard.set(raw, forKey: identityCacheKey)
    }

    // MARK: - 批量识别

    /// 对一批 host 做识别：并行 connect → 等状态沉淀 → 串行读身份 → 全部断开。
    /// 返回 host -> (model, suffix)。
    private static func identifyMany(hosts: [String]) async -> [String: (model: String, suffix: String)] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let client = ADBClient.shared()
                func target(_ host: String) -> String { "\(host):5555" }

                // ① 并行发起 connect —— 每次握手动辄一两秒，串行是慢的主因
                let group = DispatchGroup()
                for host in hosts {
                    group.enter()
                    DispatchQueue.global(qos: .utility).async {
                        _ = client.executeADBCommand(["connect", target(host)], returnCode: nil)
                        group.leave()
                    }
                }
                _ = group.wait(timeout: .now() + 12)

                // ② 等状态沉淀：offline/authorizing 的等它变 device（最多 8 秒）
                let deadline = Date().addingTimeInterval(8)
                while Date() < deadline {
                    let states = parseDeviceStates(client.executeADBCommand(["devices"], returnCode: nil))
                    let pending = hosts.contains { host in
                        let state = states[target(host)]
                        return state == nil || state == "offline"
                            || state == "connecting" || state == "authorizing"
                    }
                    if !pending { break }
                    Thread.sleep(forTimeInterval: 0.3)
                }

                // ③ 串行读身份（transport 已就绪，快）；型号+序列号一次拿
                var result: [String: (model: String, suffix: String)] = [:]
                for host in hosts {
                    let t = target(host)
                    var rc: Int32 = 0
                    let output = client.executeADBCommand(
                        ["-s", t, "shell", "getprop ro.serialno; getprop ro.product.model"],
                        returnCode: &rc
                    )
                    let lines = output.split(separator: "\n")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    if rc == 0, lines.count >= 2 {
                        let serial = lines[0]
                        let model = lines[1]
                        if serial.count >= 4, !model.isEmpty {
                            result[host] = (model, String(serial.suffix(4)))
                            print("[DeviceDiscovery] \(host) -> \(model)-\(serial.suffix(4))")
                        }
                    }
                    // 认完人就撤 —— 设备表保洁第一道防线（别留临时连接炸 push）
                    _ = client.executeADBCommand(["disconnect", t], returnCode: nil)
                }

                continuation.resume(returning: result)
            }
        }
    }

    /// 解析 `adb devices` 输出：addr -> state
    private static func parseDeviceStates(_ output: String) -> [String: String] {
        var states: [String: String] = [:]
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("List of devices") { continue }
            let parts = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 2 else { continue }
            states[parts[0]] = parts[1]
        }
        return states
    }

    // MARK: - frps 在线名单

    /// 返回（发现的设备, 错误说明）。纯数据进出，错误由调用方贴到界面上。
    private static func fetchFrpOnline() async -> ([DiscoveredDevice], String?) {
        let settings = FrpSettings.load()
        guard !settings.serverAddr.isEmpty else {
            return ([], "frps not configured")
        }
        guard !settings.adminUser.isEmpty, !settings.adminPass.isEmpty else {
            return ([], "need frps admin account")
        }

        guard let url = URL(string: "http://\(settings.serverAddr):\(settings.adminPort)/api/proxy/xtcp") else {
            return ([], "bad frps address")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let credential = Data("\(settings.adminUser):\(settings.adminPass)".utf8).base64EncodedString()
        request.setValue("Basic \(credential)", forHTTPHeaderField: "Authorization")

        let json: [String: Any]? = await withCheckedContinuation { continuation in
            URLSession.shared.dataTask(with: request) { data, _, error in
                guard let data, error == nil,
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: object)
            }.resume()
        }

        guard let json, let proxies = json["proxies"] as? [[String: Any]] else {
            return ([], "frps admin unreachable")
        }

        var found: [DiscoveredDevice] = []
        for proxy in proxies {
            guard let name = proxy["name"] as? String,
                  name.hasPrefix("phone-"), !name.hasSuffix("-tcp") else { continue }
            let parts = name.split(separator: "-").map(String.init)
            guard parts.count >= 3 else { continue }
            let suffix = parts[parts.count - 1]
            let model = parts[1..<(parts.count - 1)].joined(separator: "-")
            found.append(DiscoveredDevice(id: "\(model)-\(suffix)",
                                          model: model,
                                          suffix: suffix,
                                          lanHost: nil,
                                          frpProxyName: name))
        }

        // 再拉一次 tcp 名单：中转端口（remotePort）在那边 —— 「家里 IPv6 中转」灯要用。
        // 失败也不影响主流程（只是中转灯不亮）。
        var relayPorts: [String: Int] = [:]   // proxy 基名（phone-xxx）→ remotePort
        if let urlTcp = URL(string: "http://\(settings.serverAddr):\(settings.adminPort)/api/proxy/tcp") {
            var reqTcp = URLRequest(url: urlTcp)
            reqTcp.timeoutInterval = 12
            reqTcp.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            reqTcp.setValue("Basic \(credential)", forHTTPHeaderField: "Authorization")

            let jsonTcp: [String: Any]? = await withCheckedContinuation { continuation in
                URLSession.shared.dataTask(with: reqTcp) { data, _, error in
                    guard let data, error == nil,
                          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: object)
                }.resume()
            }

            if let proxiesTcp = jsonTcp?["proxies"] as? [[String: Any]] {
                for proxy in proxiesTcp {
                    guard let name = proxy["name"] as? String, name.hasSuffix("-tcp") else { continue }
                    let base = String(name.dropLast(4))
                    if let conf = proxy["conf"] as? [String: Any],
                       let rp = conf["remotePort"] as? Int {
                        relayPorts[base] = rp
                    }
                }
            }
        }

        for i in found.indices {
            if let proxy = found[i].frpProxyName, let rp = relayPorts[proxy] {
                found[i].relayPort = rp
            }
        }
        return (found, nil)
    }
}

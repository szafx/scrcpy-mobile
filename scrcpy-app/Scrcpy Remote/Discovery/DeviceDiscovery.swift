//
//  DeviceDiscovery.swift
//  Scrcpy Remote
//
//  「发现设备」的统一数据源（Devices 页的扫描面板用）：
//    · 局域网组：扫网段 → 批量识别（型号 + 序列号后4位）→ 认完立即断开
//    · frpc 在线组：拉 frps 管理接口（webServer）的在线 proxy 名单
//    · 合并：同一台（型号 + 序列号后4位相同）两边都出现时合成一行，
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
    let id: String              // "<型号>-<序列号后4位>"，如 COR-AL10-1911
    let model: String           // COR-AL10
    let suffix: String          // 1911
    var lanHost: String?        // 局域网地址（nil = 不在局域网）
    var frpProxyName: String?   // frpc 在线时的 proxy 名（nil = 没挂 frpc）
    var relayPort: Int?         // frpc 的 -tcp remotePort（6000~6099；nil = 不知道）
    var tailnetOnline: Bool = false  // tailnet 探针结果（装了带 relay 的新版 FrpcApp 且在线）

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
    }

    /// 显示用名字：用户起过名就用它，否则「型号 · 后4位」
    func name(for device: DiscoveredDevice) -> String {
        if let custom = customNames[device.id], !custom.isEmpty {
            return custom
        }
        return device.displayName
    }

    /// 重命名（空字符串 = 恢复默认）
    func rename(_ device: DiscoveredDevice, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            customNames.removeValue(forKey: device.id)
        } else {
            customNames[device.id] = trimmed
        }
        UserDefaults.standard.set(customNames, forKey: Self.customNamesKey)
    }

    /// 跑一轮完整发现：先 frpc 名单（快），再局域网扫描 + 批量识别（逐台出现）。
    func run() async {
        guard !running else { return }   // 已在跑（预热/上一次下拉刷新）就复用那一轮
        running = true
        devices = []
        frpError = nil

        phase = "Getting frpc online devices…"
        let (frpDevices, frpErr) = await Self.fetchFrpOnline()
        frpError = frpErr
        merge(frpDevices)

        phase = "Scanning LAN…"
        // ★ 走共享扫描（复用预热任务/最近缓存）—— 直接调 LanDiscovery.discover()
        //   会和启动预热扫描并发跑两份 253 地址扫描，这就是 2026-10-07 实测的卡顿来源。
        let candidates = await SessionNetworking.shared.sharedLanCandidates()

        // ① 命中过的设备先用缓存**立即上屏**（识别结果几乎不变：序列号不会变）
        let cache = Self.loadIdentityCache()
        var needIdentify: [String] = []
        for candidate in candidates {
            if let cached = cache[candidate.host] {
                merge([DiscoveredDevice(id: "\(cached.0)-\(cached.1)",
                                        model: cached.0,
                                        suffix: cached.1,
                                        lanHost: candidate.host,
                                        frpProxyName: nil)])
            } else {
                needIdentify.append(candidate.host)
            }
        }

        // ② 没缓存过的批量识别（并行握手 + 串行读身份）
        if !needIdentify.isEmpty {
            phase = "Identifying devices…"
            let identified = await Self.identifyMany(hosts: needIdentify)
            var newCache = cache
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

        phase = devices.isEmpty ? "No devices found" : "Done"
        running = false
        // 顺手探一遍 tailnet（首页 TS 灯）
        await refreshTailnetStatus()
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

        // 2) 已经从 frps 掉线的设备：清掉 frp 标记（打洞/中转灯变灰）
        let onlineIds = Set(frpDevices.map { $0.id })
        for i in devices.indices {
            if devices[i].frpProxyName != nil && !onlineIds.contains(devices[i].id) {
                devices[i].frpProxyName = nil
                devices[i].relayPort = nil
            }
        }

        // 3) tailnet 探针
        await refreshTailnetStatus()

        // 4) 已知局域网地址的存活探测（每台一个 0.6s 往返；几台就几个包）
        await refreshLanLiveness()
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

    /// 对 frpc 在线的设备探一遍 tailnet（首页 TS 灯）。
    ///
    /// 名字约定：tailnet 节点名 = frpc 的 proxy 名全小写
    /// （见 FrpcApp 的 TsnetRunner：`TS_HOSTNAME = proxyName.lowercase()`），
    /// 所以拼上本节点的 MagicDNS 后缀就是它的全名。
    func refreshTailnetStatus() async {
        guard TailscaleManager.shared.isStarted(),
              let suffix = TailscaleManager.shared.magicDNSSuffix() else {
            for i in devices.indices { devices[i].tailnetOnline = false }
            return
        }

        let targets: [(Int, String)] = devices.enumerated().compactMap { (idx, dev) in
            guard let proxy = dev.frpProxyName else { return nil }
            return (idx, "\(proxy.lowercased()).\(suffix)")
        }
        guard !targets.isEmpty else { return }

        let results = await withTaskGroup(of: (Int, Bool).self) { group -> [(Int, Bool)] in
            for (idx, fqdn) in targets {
                group.addTask {
                    let ok = await withCheckedContinuation { cont in
                        DispatchQueue.global(qos: .utility).async {
                            cont.resume(returning: TailscaleManager.shared.probe(host: fqdn))
                        }
                    }
                    return (idx, ok)
                }
            }
            var out: [(Int, Bool)] = []
            for await r in group { out.append(r) }
            return out
        }

        for (idx, ok) in results where idx < devices.count {
            devices[idx].tailnetOnline = ok
        }
    }

    // MARK: - 合并

    private func merge(_ incoming: [DiscoveredDevice]) {
        for device in incoming {
            if let index = devices.firstIndex(where: { $0.id == device.id }) {
                if let lan = device.lanHost { devices[index].lanHost = lan }
                if let frp = device.frpProxyName { devices[index].frpProxyName = frp }
                if let rp = device.relayPort { devices[index].relayPort = rp }
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

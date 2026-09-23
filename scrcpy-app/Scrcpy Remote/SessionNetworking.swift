//
//  SessionNetworking.swift
//  Scrcpy Remote
//
//  Created by Ethan on 12/14/24.
//

import Foundation
import Network

/// Result of network configuration resolution
struct NetworkConnectionInfo {
    let host: String
    let port: String
    let isUsingTailscale: Bool
    /// 是否经内嵌 frp XTCP visitor 转发（被控端挂着代理、用不了 Tailscale 时走这条）
    let isUsingFrp: Bool
    let originalHost: String
    let originalPort: String
    let localForwardPort: Int?

    var description: String {
        if isUsingFrp, let forwardPort = localForwardPort {
            return "frp XTCP: \(originalHost):\(originalPort) -> 127.0.0.1:\(forwardPort)"
        } else if isUsingTailscale, let forwardPort = localForwardPort {
            return "Tailscale: \(originalHost):\(originalPort) -> 127.0.0.1:\(forwardPort)"
        } else {
            return "Direct: \(host):\(port)"
        }
    }
}

/// Manages network connections for sessions, handling both direct and Tailscale connections
class SessionNetworking {
    static let shared = SessionNetworking()

    // Port range for local forwarding
    private let forwardPortMin = 20000
    private let forwardPortMax = 30000

    // Track active sessions and their port forwards
    private var activeSessionForwards: [UUID: (host: String, port: Int, localPort: Int)] = [:]

    /// 当前哪条会话在用内嵌 frp 隧道（同一时刻只跑一条 —— libfrp 的 C 接口就是单例）
    private var activeFrpSession: UUID?

    // MARK: - 局域网失败回落

    /// 本次连接是不是走的局域网直连。
    ///
    /// 用途：局域网这条路有个**竞态** —— 存活验证通过之后、真正连上之前，
    /// WiFi 可能刚好断掉，于是直连失败。这种失败不该让用户手动重试，
    /// 应该自动改走隧道（隧道本来就能通）。
    private(set) var lastAttemptWasLAN = false

    /// 已经回落到隧道重试过一次。只回落一次，避免来回循环。
    private var didFallbackToTunnel = false

    /// 让下一次连接强制跳过局域网那一级。
    func skipLANOnNextAttempt() {
        didFallbackToTunnel = true
    }

    /// 用户主动发起新连接时调用，清掉上次的回落痕迹。
    func resetLANFallbackState() {
        didFallbackToTunnel = false
        lastAttemptWasLAN = false
    }

    // Status callback for UI updates (e.g., "Regenerating auth key...")
    var statusUpdateCallback: ((String) -> Void)?

    private init() {
        loadPersistedCaches()
    }

    // MARK: - 缓存持久化

    /// ★ 为什么必须存盘：这两个缓存原本只在内存里，**App 一退就清空** ——
    ///   于是每次重开 App 都要全量扫 253 个地址（1~2 秒），
    ///   用户体感就是「每次以 WiFi 状态重进 App 都很慢，要等一会儿才能连上」。
    ///
    ///   存下来之后，重开 App 时先用上次的地址做一次 0.5 秒存活探测，
    ///   通了直接连，**根本不用扫**。
    ///
    /// 注意：恢复出来的缓存**必须先验证再用**（见 findLanHost），
    /// 所以这里不存时间戳 —— 地址有没有效，验证一次就知道，比看时间戳可靠。
    private let rememberedHostsKey = "session_networking.remembered_lan_hosts"
    private let scanCacheKey = "session_networking.lan_scan_cache"

    private func loadPersistedCaches() {
        let defaults = UserDefaults.standard

        if let raw = defaults.dictionary(forKey: rememberedHostsKey) as? [String: String] {
            for (key, value) in raw {
                if let uuid = UUID(uuidString: key) {
                    sessionLanHosts[uuid] = value
                }
            }
            print("[LanDiscovery] 从磁盘恢复 \(sessionLanHosts.count) 条会话地址记忆")
        }

        if let hosts = defaults.stringArray(forKey: scanCacheKey), !hosts.isEmpty {
            lanScanCache = hosts.map { LanDiscovery.Candidate(host: $0, port: 5555) }
            print("[LanDiscovery] 从磁盘恢复 \(hosts.count) 个候选地址（待验证）：\(hosts)")
        }
    }

    private func persistCaches() {
        let defaults = UserDefaults.standard
        defaults.set(sessionLanHosts.reduce(into: [String: String]()) { $0[$1.key.uuidString] = $1.value },
                     forKey: rememberedHostsKey)
        defaults.set(lanScanCache.map { $0.host }, forKey: scanCacheKey)
    }

    // MARK: - Public Methods

    /// Get the final connection info for a session
    /// - Parameter session: The session configuration
    /// - Returns: NetworkConnectionInfo with resolved connection details, or nil if setup failed
    func getConnectionInfo(for session: ScrcpySessionModel) async -> NetworkConnectionInfo? {
        let originalHost = session.hostReal
        let originalPort = session.port

        // ★ 三级降级的第一级：自动找局域网里的手机。
        //
        //   注意这里**不需要用户填任何 IP** —— 手机在局域网里的地址是 DHCP 分的、
        //   随时会变，让用户手填等于让他维护一份会过期的表，那「优先走局域网」就是假的。
        //   所以自己扫：先查缓存（0.5s 探测），没命中再扫一遍网段。
        //
        //   必须放在 frp / Tailscale **之前** —— 否则勾了隧道开关就永远走隧道，
        //   明明在家连着同一个 WiFi 也要绕出去，白白多几十毫秒。
        // ★ 一次性读取「这次要不要跳过局域网」，读完立刻复位 ——
        //   否则一次回落会让**之后每一次**连接都不走局域网了。
        let skipLAN = didFallbackToTunnel
        didFallbackToTunnel = false

        // 注意：这里**不能**先喊「正在扫描局域网」——
        // 要不要扫得等 findLanHost 里查过 isOnWiFi() 才知道。
        // 之前把提示放在这儿，结果蜂窝下界面显示"正在扫描局域网"、实际压根没扫，
        // 纯属骗人（用户实测反馈过）。提示现在由 findLanHost 在真正开扫时发出。
        if session.useFrp || session.useTailscale, !skipLAN,
           let lanHost = await findLanHost(portText: originalPort, session: session) {
            print("[SessionNetworking] 局域网里发现目标 \(lanHost):\(originalPort) —— 直连，跳过隧道")
            statusUpdateCallback?("已找到局域网设备，正在直连…")
            // 记下来：万一这个直连因为「验证之后 WiFi 刚好断掉」而失败，
            // 连接管理器会据此自动改走隧道重试（见 lastAttemptWasLAN）。
            lastAttemptWasLAN = true
            return NetworkConnectionInfo(
                host: lanHost,
                port: originalPort,
                isUsingTailscale: false,
                isUsingFrp: false,
                originalHost: lanHost,
                originalPort: originalPort,
                localForwardPort: nil
            )
        }
        // 走到这儿说明这次不走局域网（不在 WiFi / 认不出来 / 已经回落过）
        lastAttemptWasLAN = false

        // frp XTCP：被控端不占 VpnService（要挂代理），App 端也不占 VPN 槽
        if session.useFrp {
            return await setupFrpConnection(session: session)
        }

        // If not using Tailscale, return direct connection
        guard session.useTailscale else {
            return NetworkConnectionInfo(
                host: originalHost,
                port: originalPort,
                isUsingTailscale: false,
                isUsingFrp: false,
                originalHost: originalHost,
                originalPort: originalPort,
                localForwardPort: nil
            )
        }
        
        // For Tailscale connections, set up port forwarding
        return await setupTailscaleConnection(
            sessionId: session.id,
            remoteHost: originalHost,
            remotePort: Int(originalPort) ?? 0
        )
    }
    
    /// Stop port forwarding for a specific session
    /// - Parameter sessionId: The session ID
    /// - Returns: true if successful or no forwarding was active
    func stopForwarding(for sessionId: UUID) -> Bool {
        // 先把 frp 那条停了（如果这条会话正占着）
        if activeFrpSession == sessionId {
            FrpTunnel.shared.stop()
            activeFrpSession = nil
            print("[SessionNetworking] Stopped frp tunnel for session \(sessionId)")
        }

        guard let forward = activeSessionForwards[sessionId] else {
            // No active forwarding for this session
            return true
        }
        
        let success = TailscaleManager.shared.stopForward(
            remoteAddr: forward.host,
            remotePort: forward.port,
            localPort: forward.localPort
        )
        
        if success {
            activeSessionForwards.removeValue(forKey: sessionId)
            print("[SessionNetworking] Stopped forwarding for session \(sessionId)")
        } else {
            print("[SessionNetworking] Failed to stop forwarding for session \(sessionId)")
        }
        
        return success
    }
    
    /// Stop all active port forwards
    /// - Returns: true if successful
    func stopAllForwarding() -> Bool {
        var sessionIds = Array(activeSessionForwards.keys)
        // frp 那条不记在 activeSessionForwards 里，单独带上
        if let frpSessionId = activeFrpSession, !sessionIds.contains(frpSessionId) {
            sessionIds.append(frpSessionId)
        }
        var allSuccess = true
        
        for sessionId in sessionIds {
            if !stopForwarding(for: sessionId) {
                allSuccess = false
            }
        }
        
        return allSuccess
    }
    
    /// Get information about active forwards
    /// - Returns: Dictionary of session IDs to their forward info
    func getActiveForwards() -> [UUID: (host: String, port: Int, localPort: Int)] {
        return activeSessionForwards
    }
    
    // MARK: - Private Methods
    
    /// Set up Tailscale connection and port forwarding
    private func setupTailscaleConnection(sessionId: UUID, remoteHost: String, remotePort: Int) async -> NetworkConnectionInfo? {
        let manager = TailscaleManager.shared

        // Check if auth key needs regeneration before connecting
        if manager.isAuthKeyExpired() {
            if manager.canAutoRegenerateAuthKey() {
                statusUpdateCallback?("Tailscale 授权已过期，正在重新获取…")
                print("[SessionNetworking] Auth key expired, attempting auto-regeneration")

                let regenerated = await withCheckedContinuation { continuation in
                    manager.autoRegenerateAuthKeyIfNeeded { success, error in
                        if let error = error {
                            print("[SessionNetworking] Auth key regeneration failed: \(error)")
                        }
                        continuation.resume(returning: success)
                    }
                }

                if regenerated {
                    statusUpdateCallback?("Tailscale 授权已刷新")
                    print("[SessionNetworking] Auth key regenerated successfully")
                } else {
                    statusUpdateCallback?("Tailscale 授权刷新失败")
                    print("[SessionNetworking] Failed to regenerate auth key, connection may fail")
                    // Continue anyway - the old key might still work
                }
            } else {
                print("[SessionNetworking] Auth key expired but OAuth not configured for auto-regeneration")
                statusUpdateCallback?("Tailscale 授权已过期，请到设置里配置 OAuth 才能自动续期")
            }
        }

        // Check if Tailscale configuration is valid
        guard manager.isConfigurationValid() else {
            print("[SessionNetworking] Tailscale configuration is invalid")
            let configStatus = manager.getConfigurationStatus()
            print("[SessionNetworking] Configuration status: \(configStatus)")
            statusUpdateCallback?("Tailscale 配置无效，请到 设置 → Tailscale 里检查")
            return nil
        }

        statusUpdateCallback?("正在连接 Tailscale…")

        // Ensure Tailscale is connected
        guard manager.ensureConnected() else {
            print("[SessionNetworking] Failed to ensure Tailscale connection")
            if let lastError = manager.getLastError() {
                print("[SessionNetworking] Tailscale error: \(lastError)")
                statusUpdateCallback?("Tailscale 出错：\(lastError)")
            }
            return nil
        }

        statusUpdateCallback?("等待 Tailscale 连接…")

        // Wait for connection to be established
        let connected = await waitForTailscaleConnection(timeout: 30.0)
        guard connected else {
            print("[SessionNetworking] Tailscale connection timeout")
            if let lastError = manager.getLastError() {
                print("[SessionNetworking] Tailscale error after timeout: \(lastError)")
                statusUpdateCallback?("连接超时：\(lastError)")
            } else {
                statusUpdateCallback?("Tailscale 连接超时")
            }
            return nil
        }

        statusUpdateCallback?("正在设置 Tailscale 端口转发…")

        // Find available local port
        guard let localPort = findAvailablePort() else {
            print("[SessionNetworking] No available ports in range \(forwardPortMin)-\(forwardPortMax)")
            statusUpdateCallback?("没有可用的本地端口，请先释放一些")
            return nil
        }

        // Stop existing forward for this session if any
        _ = stopForwarding(for: sessionId)

        // Start port forwarding
        let success = manager.startForward(
            remoteAddr: remoteHost,
            remotePort: remotePort,
            localPort: localPort
        )

        guard success else {
            print("[SessionNetworking] Failed to start port forwarding: \(remoteHost):\(remotePort) -> 127.0.0.1:\(localPort)")
            if let lastError = manager.getLastError() {
                print("[SessionNetworking] Port forwarding error: \(lastError)")
                statusUpdateCallback?("端口转发失败：\(lastError)")
            }
            return nil
        }

        // Track the forward
        activeSessionForwards[sessionId] = (host: remoteHost, port: remotePort, localPort: localPort)

        print("[SessionNetworking] Started port forwarding: \(remoteHost):\(remotePort) -> 127.0.0.1:\(localPort)")
        statusUpdateCallback?("Tailscale 已连通")

        return NetworkConnectionInfo(
            host: "127.0.0.1",
            port: String(localPort),
            isUsingTailscale: true,
            isUsingFrp: false,
            originalHost: remoteHost,
            originalPort: String(remotePort),
            localForwardPort: localPort
        )
    }
    
    // MARK: - frp XTCP

    /// 用内嵌的 frp visitor 打通到被控手机的隧道。
    ///
    /// 被控端跑的是 frpc（XTCP 模式，普通进程、**不占 VpnService**，所以能挂代理），
    /// 访问端就是 App 里这块 —— 隧道建好后本 App 连 127.0.0.1:<本机端口> 即可，
    /// 和 Tailscale 那条路的用法完全一致（native 侧读的都是 hostReal）。
    private func setupFrpConnection(session: ScrcpySessionModel) async -> NetworkConnectionInfo? {
        let settings = FrpSettings.load()
        let proxyName = session.frpProxyName.trimmingCharacters(in: .whitespaces)

        if let error = settings.validationError(proxyName: proxyName) {
            print("[SessionNetworking] frp 配置不完整: \(error)")
            statusUpdateCallback?(error)
            return nil
        }

        // 同一条隧道已经跑着就直接复用（省一次打洞，隧道本来就该常驻）
        if FrpTunnel.shared.isRunning(for: proxyName) {
            let reused = Int(FrpTunnel.shared.localPort)
            print("[SessionNetworking] 复用已有的 frp 隧道: 127.0.0.1:\(reused)")
            statusUpdateCallback?("复用已有隧道，正在连接…")
            return frpConnectionInfo(session: session, localPort: reused)
        }

        statusUpdateCallback?("局域网不可用，正在建立 frp 隧道…")

        // 本机监听端口和 Tailscale 共用同一个池子，避免撞车
        guard let localPort = findAvailablePort() else {
            print("[SessionNetworking] No available ports in range \(forwardPortMin)-\(forwardPortMax)")
            statusUpdateCallback?("没有可用的本地端口，请先释放一些")
            return nil
        }

        // 先腾干净：libfrp 的 C 接口是单例，同一时刻只能有一条隧道。
        // 换手机 / 换 proxy 名时，上一条必须先停掉，否则 activeFrpSession 会指向旧的。
        if let previous = activeFrpSession {
            _ = stopForwarding(for: previous)
        }
        _ = stopForwarding(for: session.id)

        guard let port = FrpTunnel.shared.start(
            serverAddr: settings.serverAddr,
            serverPort: settings.serverPort,
            token: settings.token,
            stunServer: settings.stunServer,
            proxyName: proxyName,
            secretKey: settings.secretKey,
            baseDir: FrpTunnel.defaultBaseDir,
            preferredPort: Int32(localPort)
        ) else {
            let err = FrpTunnel.shared.lastErrorText
            print("[SessionNetworking] frp visitor 启动失败: \(err)")
            statusUpdateCallback?("frp 隧道建立失败：\(err)")
            return nil
        }

        activeFrpSession = session.id

        // ⚠️ frpc 起来 ≠ 隧道通了：visitor 的本机监听是异步建的，而且第一次
        //    连接还要现场打洞。不等一下直接 adb connect 会偶发 Connection refused。
        statusUpdateCallback?("隧道已建立，正在打通链路（P2P 打洞，不通会自动转中转）…")
        guard await waitForLocalPort(port, timeout: 15.0) else {
            print("[SessionNetworking] frp 本机端口 \(port) 一直没起来（\(FrpTunnel.shared.status)）")
            statusUpdateCallback?("frp 隧道超时：打洞和中转都没能建立连接")
            _ = stopForwarding(for: session.id)
            return nil
        }

        print("[SessionNetworking] frp 隧道就绪: \(session.hostReal):\(session.port) -> 127.0.0.1:\(port)")
        statusUpdateCallback?("frp 隧道就绪")
        watchFrpTunnelDecision()
        return frpConnectionInfo(session: session, localPort: Int(port))
    }

    /// 盯着 frp 到底走了「P2P 打洞」还是「退回中转」，把结果报给界面。
    ///
    /// 为什么要读日志：frp 内部选哪条路是它自己决定的，**没有运行时回调**，
    /// 只能读 visitor 自己写的 `frpc_visitor.log`。
    /// 用户明确希望能看到「P2P 打洞失败，正在走 frp 中转」这种提示。
    ///
    /// 只轮询十几秒就收工 —— 打洞结果一般几秒内就出，长跑没意义。
    private func watchFrpTunnelDecision() {
        let logPath = (FrpTunnel.defaultBaseDir as NSString).appendingPathComponent("frpc_visitor.log")

        DispatchQueue.global(qos: .utility).async { [weak self] in
            // 从文件末尾往前读，只看最近的内容，免得被历史记录误导
            func readTail() -> String? {
                guard let handle = FileHandle(forReadingAtPath: logPath) else { return nil }
                defer { try? handle.close() }
                let size = (try? handle.seekToEnd()) ?? 0
                let window: UInt64 = 8192
                let offset = size > window ? size - window : 0
                try? handle.seek(toOffset: offset)
                guard let data = try? handle.readToEnd() else { return nil }
                return String(data: data, encoding: .utf8)
            }

            for _ in 0..<15 {
                Thread.sleep(forTimeInterval: 1.0)
                guard let tail = readTail() else { continue }

                if tail.contains("nat hole connection successful") {
                    DispatchQueue.main.async {
                        self?.statusUpdateCallback?("P2P 打洞成功，正在直连…")
                    }
                    return
                }
                if tail.contains("make hole error") {
                    DispatchQueue.main.async {
                        self?.statusUpdateCallback?("P2P 打洞未成功，正在走 frp 中转…")
                    }
                    return
                }
            }
        }
    }

    /// 组装 frp 隧道的连接信息（host 指到本机，native 侧走 hostReal）。
    private func frpConnectionInfo(session: ScrcpySessionModel, localPort: Int) -> NetworkConnectionInfo {
        return NetworkConnectionInfo(
            host: "127.0.0.1",
            port: String(localPort),
            isUsingTailscale: false,
            isUsingFrp: true,
            originalHost: session.hostReal,
            originalPort: session.port,
            localForwardPort: localPort
        )
    }

    /// 轮询本机端口，直到能连上为止。
    private func waitForLocalPort(_ port: Int32, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if isPortConnectable(port: port) {
                return true
            }
            try? await Task.sleep(nanoseconds: 250_000_000) // 0.25 秒
        }

        return false
    }

    // MARK: - 局域网自动发现

    /// 上次扫描的结果和时刻。扫一遍网段要 1~2 秒，不能每次连接都扫。
    private var lanScanCache: [LanDiscovery.Candidate] = []
    private var lanScanAt: Date?
    /// 正在跑的扫描任务 —— 预热和连接时都可能触发，复用它避免并发扫两次
    private var lanScanTask: Task<[LanDiscovery.Candidate], Never>?

    /// 会话 → 上次成功连上的局域网地址。
    /// 认过一次就记住，别再查 —— 查序列号要 adb connect 走一遍授权握手
    /// （offline → authorizing → device），又慢又会让设备表短暂变脏。
    private var sessionLanHosts: [UUID: String] = [:]
    /// 缓存有效期 —— 过期就重扫（手机换了 IP、或者换了 WiFi）
    private let lanScanTTL: TimeInterval = 300

    /// 后台预热：App 一起来就扫一遍，真正连接时直接命中缓存、不额外等。
    func warmUpLanDiscovery(port: UInt16 = 5555) {
        Task { _ = await discoverLan(port: port) }
    }

    /// 返回局域网里属于**这台设备**的地址；不在局域网（或认不出来）就返回 nil。
    ///
    /// 匹配顺序（快的在前，慢的兜底）：
    ///   1. **这个会话上次连过的地址**还在候选里 → 直接用（零额外开销）
    ///   2. 只有一台候选 → 直接用（没有歧义）
    ///   3. 多台 → 逐个用 adb 连上去读序列号，和会话 frp proxy 名里的序号段对上才算
    ///   4. 认不出来 → 返回 nil，**不猜**，让调用方落到 frp/Tailscale
    ///
    /// ★ 为什么第 1 条这么重要：读序列号要 `adb connect`，而每次 connect 都要走一遍
    ///   `offline → authorizing → device` 的授权握手，慢，还会让 adb 设备表短暂变脏
    ///   （并发跑更糟，经常读到空的序列号导致匹配失败）。所以认过一次就记下来。
    private func findLanHost(portText: String, session: ScrcpySessionModel) async -> String? {
        guard let port = UInt16(portText.trimmingCharacters(in: .whitespaces)) else { return nil }

        // ★ 第一步：先单独验证「这个会话上次连过的地址」。
        //
        //   放在最前面有两个好处：
        //     1. 命中的话只花**一次**探测（1 秒），不用去验证一整批候选
        //     2. 不通就当场把这条记忆删掉 —— 手机多半换 IP 了，
        //        留着只会让**以后每次连接都白等一次探测**，而且它永远不会自己消失。
        //        （用户提的：通了就留着、不通就该清掉）
        if let remembered = sessionLanHosts[session.id] {
            if await isAlive(host: remembered, port: port, timeout: 1.0) {
                print("[LanDiscovery] 用这个会话上次的地址：\(remembered)")
                return remembered
            }
            print("[LanDiscovery] 会话上次的地址 \(remembered) 已失效（手机多半换 IP 了），清掉这条记忆")
            sessionLanHosts.removeValue(forKey: session.id)
            persistCaches()
        }

        // 先看缓存：对上次见过（或上次扫到）的地址做一次**真实往返**验证，活的才留下。
        //
        // ★ 这里**不看时间戳** —— 缓存可能是从磁盘恢复出来的（App 刚重启，
        //   时间戳是 nil）。地址本身有没有效，验证一下就知道，比看时间戳可靠。
        //
        // ★ 也不能用 NWConnection 的 ready 状态：切网瞬间（WiFi→蜂窝）WiFi 接口
        //   还没消失，它可能仍报 ready，但包已经出不去了。
        var candidates: [LanDiscovery.Candidate] = []
        if !lanScanCache.isEmpty {
            candidates = await withTaskGroup(of: (LanDiscovery.Candidate, Bool).self) { group -> [LanDiscovery.Candidate] in
                for candidate in lanScanCache {
                    group.addTask {
                        (candidate, await self.isAlive(host: candidate.host, port: port, timeout: 1.0))
                    }
                }
                var hits: [LanDiscovery.Candidate] = []
                for await (candidate, ok) in group {
                    if ok { hits.append(candidate) }
                }
                return hits
            }
        }

        // 缓存里活着的都不在了（或者压根没有缓存）→ 需要重扫一遍。
        //
        // ★★ 这里有个曾经踩过的坑：**不能去调一个"会返回缓存"的重扫函数**。
        //    缓存的存活验证刚刚才失败（蜂窝下 4 台当然都不通），如果重扫又把那份
        //    旧缓存原样端回来，等于把刚验证过已经死掉的地址复活了 ——
        //    实测就是这么拿着 192.168.167.169 去直连、然后失败。
        //    所以这里要么**真的扫一遍**，要么（不在 WiFi 上）直接放弃。
        if candidates.isEmpty {
            guard LanDiscovery.isOnWiFi() else {
                print("[LanDiscovery] 缓存已失效且当前不在 WiFi —— 直接走隧道，不扫了")
                return nil
            }
            // ★ 确认真的要扫了才发提示 —— 放在这儿界面才不会骗人。
            statusUpdateCallback?("正在扫描局域网，寻找可直连的设备…")
            candidates = await discoverLan(port: port)
        }
        guard !candidates.isEmpty else { return nil }

        // ① 这个会话上次连过的地址，只要还在候选里就直接用
        // ② 只有一台，不用问
        if candidates.count == 1 {
            let host = candidates[0].host
            sessionLanHosts[session.id] = host
            persistCaches()
            return host
        }

        // ③ 多台：逐个查序列号认人（慢，但结果会记住）
        print("[LanDiscovery] 局域网里有 \(candidates.count) 台，逐个查序列号匹配…")
        let matched = await matchTargetDevice(candidates, session: session, port: port)
        if let matched {
            sessionLanHosts[session.id] = matched
            persistCaches()
        }
        return matched
    }

    /// 逐个 adb 连上去读序列号，找出哪一台是会话要的那台。
    ///
    /// ★ 串行跑，别并发：几次并发 adb connect/查询会互相干扰（设备状态在 offline →
    ///   authorizing → device 之间跳），实测经常读到空序列号，白白判成「没有一台匹配」。
    ///
    /// 判据用的是 **frp proxy 名的最后一段**（部署脚本 deploy-frpc.py 的命名规则：
    /// `phone-<型号>-<序列号后4位>`），所以会话必须填过 frpProxyName。
    /// 填不出来就返回 nil —— 宁可不走局域网，也不能连错设备。
    private func matchTargetDevice(_ candidates: [LanDiscovery.Candidate],
                                   session: ScrcpySessionModel,
                                   port: UInt16) async -> String? {
        guard let suffix = Self.serialSuffix(from: session.frpProxyName), suffix.count >= 4 else {
            print("[LanDiscovery] 会话里没有可用的设备标识（frp proxy 名），多台时不猜，走隧道")
            return nil
        }

        for candidate in candidates {
            let serial = await Self.readSerialNumber(host: candidate.host, port: port)
            if let serial, serial.hasSuffix(suffix) {
                print("[LanDiscovery] 匹配到目标设备：\(candidate.host)（序列号后缀 \(suffix)）")
                return candidate.host
            }
        }

        print("[LanDiscovery] \(candidates.count) 台里没有一台匹配后缀 \(suffix)")
        return nil
    }

    /// 从 `phone-COR-AL10-1911` 里取出 `1911`
    private static func serialSuffix(from proxyName: String) -> String? {
        let trimmed = proxyName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.split(separator: "-").last.map(String.init)
    }

    /// adb connect 上某台候选，读它的序列号。
    ///
    /// 用的是 App 自己那份 adbkey（已导入过被控端的授权列表），所以不会弹授权窗。
    ///
    /// ★ 读完**必须 disconnect** —— 这个连接只是用来认人的，留着会污染 adb 的设备表，
    ///   之后 scrcpy 推 scrcpy-server 时就会炸：
    ///     adb: error: failed to copy ... : remote unknown command 32444e53
    ///   （实测：设备表里只有 1 台时 push 正常；被自动发现挂了 4 台后必失败。）
    private static func readSerialNumber(host: String, port: UInt16) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let target = "\(host):\(port)"
                let client = ADBClient.shared()
                _ = client.executeADBCommand(["connect", target], returnCode: nil)

                var rc: Int32 = 0
                let output = client.executeADBCommand(
                    ["-s", target, "shell", "getprop", "ro.serialno"],
                    returnCode: &rc
                )
                let serial = output.trimmingCharacters(in: .whitespacesAndNewlines)

                // 认完人就撤，别留下来干扰后面的 scrcpy
                _ = client.executeADBCommand(["disconnect", target], returnCode: nil)

                continuation.resume(returning: (rc == 0 && !serial.isEmpty) ? serial : nil)
            }
        }
    }

    private func discoverLan(port: UInt16) async -> [LanDiscovery.Candidate] {
        // ★ 已经有扫描在跑就复用它，别再起一个。
        //   预热扫描（App 启动时）和这里的调用会撞车：两个并发跑的话，
        //   既浪费，也会让 adb 设备表被临时连接污染两次（push 会失败）。
        if let running = lanScanTask {
            return await running.value
        }

        // ★★ 这里**故意不返回缓存**，哪怕缓存还没过期。
        //    调用方是「缓存的存活验证刚刚失败」之后才走到这儿的，
        //    这时端回旧缓存 = 把刚验证过已经死掉的地址复活 ——
        //    实测就是这么拿着 192.168.167.169 去直连、然后失败。
        //    要重扫就真扫一遍。
        let task = Task { await LanDiscovery.discover(port: port) }
        lanScanTask = task
        let found = await task.value
        lanScanTask = nil
        lanScanCache = found
        lanScanAt = Date()
        persistCaches()
        return found
    }

    /// 目标是否**真的**还活着 —— 用一次完整往返来验证，而不是只看连接状态。
    ///
    /// 为什么不用 isReachable：切网瞬间（WiFi→蜂窝）WiFi 接口还在，
    /// NWConnection 可能仍报 ready，但包已经出不去了。只有真的发一个字节、
    /// 等到对端反应（adbd 会关连接），才能确认这条路当前是通的。
    private func isAlive(host: String, port: UInt16, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let ms = LanDiscovery.measureRoundTrip(host: host, port: port, timeout: timeout)
                continuation.resume(returning: ms != nil)
            }
        }
    }

    /// 目标地址能不能连上（用来判断「现在是不是和手机在同一个局域网」）。
    ///
    /// 用 NWConnection 而不是裸 socket：它天生异步、带状态回调，超时也好控制。
    private func isReachable(host: String, portText: String, timeout: TimeInterval) async -> Bool {
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        guard !trimmedHost.isEmpty, !trimmedHost.hasPrefix("frp") else { return false }
        guard let portNumber = UInt16(portText.trimmingCharacters(in: .whitespaces)) else { return false }
        // 127.0.0.1 上探测没有意义（连的是自己）
        guard trimmedHost != "127.0.0.1", trimmedHost != "localhost" else { return false }

        return await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "com.scrcpy.lan-probe")
            let connection = NWConnection(
                host: NWEndpoint.Host(trimmedHost),
                port: NWEndpoint.Port(rawValue: portNumber) ?? .any,
                using: .tcp
            )

            // 只 resume 一次：状态回调和超时定时器都会走到这里
            var finished = false
            func finish(_ result: Bool) {
                guard !finished else { return }
                finished = true
                connection.cancel()
                continuation.resume(returning: result)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(true)
                case .failed, .cancelled:
                    finish(false)
                default:
                    break
                }
            }

            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }

    /// 本机端口能不能连上（连 127.0.0.1 失败是立刻返回的，不会挂住）。
    private func isPortConnectable(port: Int32) -> Bool {
        let socketFileDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFileDescriptor != -1 else {
            return false
        }

        defer {
            close(socketFileDescriptor)
        }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(truncatingIfNeeded: port)).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socketFileDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        return connectResult == 0
    }

    /// Wait for Tailscale connection to be established
    private func waitForTailscaleConnection(timeout: TimeInterval) async -> Bool {
        let startTime = Date()
        
        while Date().timeIntervalSince(startTime) < timeout {
            let status = TailscaleManager.shared.getConnectionStatus()
            if status == 1 && TailscaleManager.shared.isStarted() {
                return true
            } else if status == -1 {
                // Connection failed
                return false
            }
            
            // Wait a bit before checking again
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        }
        
        return false
    }
    
    /// Find an available port in the specified range
    private func findAvailablePort() -> Int? {
        // Get currently used ports
        let usedPorts = Set(activeSessionForwards.values.map { $0.localPort })
        
        // Try to find an available port
        for port in forwardPortMin...forwardPortMax {
            if !usedPorts.contains(port) && isPortAvailable(port: port) {
                return port
            }
        }
        
        return nil
    }
    
    /// Check if a port is available for binding
    private func isPortAvailable(port: Int) -> Bool {
        let socketFileDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFileDescriptor != -1 else {
            return false
        }
        
        defer {
            close(socketFileDescriptor)
        }
        
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFileDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        
        return bindResult != -1
    }
    
    // MARK: - Utility Methods
    
    /// Get connection summary for debugging
    func getConnectionSummary() -> String {
        var summary: [String] = []
        
        summary.append("Active Session Forwards: \(activeSessionForwards.count)")
        
        for (sessionId, forward) in activeSessionForwards {
            summary.append("  \(sessionId): \(forward.host):\(forward.port) -> 127.0.0.1:\(forward.localPort)")
        }
        
        if let tailscaleInfo = TailscaleManager.shared.getConnectionInfo() {
            summary.append("Tailscale Status:")
            summary.append(tailscaleInfo)
        }
        
        return summary.joined(separator: "\n")
    }
    
    /// Clean up all resources
    func cleanup() {
        _ = stopAllForwarding()
        activeSessionForwards.removeAll()
    }
} 
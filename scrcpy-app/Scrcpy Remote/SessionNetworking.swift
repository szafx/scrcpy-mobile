//
//  SessionNetworking.swift
//  Scrcpy Remote
//
//  Created by Ethan on 12/14/24.
//

import Foundation

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

    // Status callback for UI updates (e.g., "Regenerating auth key...")
    var statusUpdateCallback: ((String) -> Void)?

    private init() {}

    // MARK: - Public Methods

    /// Get the final connection info for a session
    /// - Parameter session: The session configuration
    /// - Returns: NetworkConnectionInfo with resolved connection details, or nil if setup failed
    func getConnectionInfo(for session: ScrcpySessionModel) async -> NetworkConnectionInfo? {
        let originalHost = session.hostReal
        let originalPort = session.port

        // frp XTCP 优先：被控端不占 VpnService（要挂代理），App 端也不占 VPN 槽
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
                statusUpdateCallback?("Auth key expired, regenerating...")
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
                    statusUpdateCallback?("Auth key regenerated successfully")
                    print("[SessionNetworking] Auth key regenerated successfully")
                } else {
                    statusUpdateCallback?("Failed to regenerate auth key")
                    print("[SessionNetworking] Failed to regenerate auth key, connection may fail")
                    // Continue anyway - the old key might still work
                }
            } else {
                print("[SessionNetworking] Auth key expired but OAuth not configured for auto-regeneration")
                statusUpdateCallback?("Auth key expired - configure OAuth for auto-renewal")
            }
        }

        // Check if Tailscale configuration is valid
        guard manager.isConfigurationValid() else {
            print("[SessionNetworking] Tailscale configuration is invalid")
            let configStatus = manager.getConfigurationStatus()
            print("[SessionNetworking] Configuration status: \(configStatus)")
            statusUpdateCallback?("Tailscale configuration invalid")
            return nil
        }

        statusUpdateCallback?("Connecting to Tailscale...")

        // Ensure Tailscale is connected
        guard manager.ensureConnected() else {
            print("[SessionNetworking] Failed to ensure Tailscale connection")
            if let lastError = manager.getLastError() {
                print("[SessionNetworking] Tailscale error: \(lastError)")
                statusUpdateCallback?("Tailscale error: \(lastError)")
            }
            return nil
        }

        statusUpdateCallback?("Waiting for Tailscale connection...")

        // Wait for connection to be established
        let connected = await waitForTailscaleConnection(timeout: 30.0)
        guard connected else {
            print("[SessionNetworking] Tailscale connection timeout")
            if let lastError = manager.getLastError() {
                print("[SessionNetworking] Tailscale error after timeout: \(lastError)")
                statusUpdateCallback?("Connection timeout: \(lastError)")
            } else {
                statusUpdateCallback?("Tailscale connection timeout")
            }
            return nil
        }

        statusUpdateCallback?("Setting up port forwarding...")

        // Find available local port
        guard let localPort = findAvailablePort() else {
            print("[SessionNetworking] No available ports in range \(forwardPortMin)-\(forwardPortMax)")
            statusUpdateCallback?("No available ports")
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
                statusUpdateCallback?("Port forwarding failed: \(lastError)")
            }
            return nil
        }

        // Track the forward
        activeSessionForwards[sessionId] = (host: remoteHost, port: remotePort, localPort: localPort)

        print("[SessionNetworking] Started port forwarding: \(remoteHost):\(remotePort) -> 127.0.0.1:\(localPort)")
        statusUpdateCallback?("Connected via Tailscale")

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
            statusUpdateCallback?("Reusing frp tunnel")
            return frpConnectionInfo(session: session, localPort: reused)
        }

        statusUpdateCallback?("Setting up frp tunnel...")

        // 本机监听端口和 Tailscale 共用同一个池子，避免撞车
        guard let localPort = findAvailablePort() else {
            print("[SessionNetworking] No available ports in range \(forwardPortMin)-\(forwardPortMax)")
            statusUpdateCallback?("No available ports")
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
            statusUpdateCallback?("frp tunnel failed: \(err)")
            return nil
        }

        activeFrpSession = session.id

        // ⚠️ frpc 起来 ≠ 隧道通了：visitor 的本机监听是异步建的，而且第一次
        //    连接还要现场打洞。不等一下直接 adb connect 会偶发 Connection refused。
        statusUpdateCallback?("Waiting for frp tunnel...")
        guard await waitForLocalPort(port, timeout: 15.0) else {
            print("[SessionNetworking] frp 本机端口 \(port) 一直没起来（\(FrpTunnel.shared.status)）")
            statusUpdateCallback?("frp tunnel timeout")
            _ = stopForwarding(for: session.id)
            return nil
        }

        print("[SessionNetworking] frp 隧道就绪: \(session.hostReal):\(session.port) -> 127.0.0.1:\(port)")
        statusUpdateCallback?("Connected via frp")
        return frpConnectionInfo(session: session, localPort: Int(port))
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
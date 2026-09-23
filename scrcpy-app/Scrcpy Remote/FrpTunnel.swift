//
//  FrpTunnel.swift
//  Scrcpy Remote
//
//  内嵌的 frp visitor —— 和被控手机上跑的 frpc（XTCP 模式）打洞。
//
//  为什么需要它：
//    被控端要能挂代理（跑快手极速版要），代理占 VpnService，
//    所以安卓上不能用 Tailscale。而 frpc 是普通进程、不占 VpnService，
//    但 frp 的 TCP 模式只走中转 —— 要 P2P 就得用 XTCP，
//    而 XTCP 需要访问端有一个 visitor 跟它配对。iOS 上装不了独立客户端，
//    所以把 frp 的 client 编成静态库嵌进来（见 porting/libfrp）。
//
//  用法：
//    FrpTunnel.shared.start(...)   →  返回一个本机端口
//    adb 连 127.0.0.1:<那个端口>   →  流量经 XTCP 隧道到被控手机
//
//  ★ 关键：natHoleStunServer 必须填国内的。
//    frp 默认用 stun.easyvoip.com，国内手机网络连不上，
//    报 "wait response from stun server timeout"，打洞直接死在第一步。
//

import Foundation

final class FrpTunnel {

    static let shared = FrpTunnel()

    /// 当前隧道占用的本机端口（0 表示没跑）
    private(set) var localPort: Int32 = 0
    private(set) var isRunning = false

    /// 上次用过的本机端口 —— stop() 后**故意保留**。
    ///
    /// ★ 为什么必须记住它：SessionNetworking 是用 `findAvailablePort()` 挑端口的，
    ///   而那个函数只判断"现在空不空"。万一旧 visitor 没停干净、端口仍被自己占着，
    ///   它就会挑一个**不同的**端口 —— 真机日志里就是这么坏的：
    ///     127.0.0.1:20000   device      ← 真正在监听、能用的
    ///     127.0.0.1:20002   offline     ← App 以为隧道在这里，连它 Connection refused
    ///   结果是界面显示"frp 隧道就绪"，scrcpy 却对着一个没人监听的端口死磕。
    ///   重建时复用同一个端口就不会出现这种错位。
    private(set) var lastUsedPort: Int32 = 0

    /// 正在打洞的那条 proxy 名（用来判断「同一条隧道是不是已经跑着了」）
    private(set) var currentProxyName: String = ""

    /// 国内可用的 STUN 服务器（2026-09 实测）
    static let defaultStunServer = "stun.miwifi.com:3478"

    /// 配置目录：App 沙盒的 Library/frp（和 TailscaleState 同级）
    static var defaultBaseDir: String {
        let libraryPath = NSSearchPathForDirectoriesInDomains(.libraryDirectory, .userDomainMask, true).first
            ?? NSTemporaryDirectory()
        return (libraryPath as NSString).appendingPathComponent("frp")
    }

    private init() {}

    /// 启动一条 XTCP visitor 隧道。
    ///
    /// - Parameters:
    ///   - serverAddr: frps 地址（如 `home.szafx.icu`）
    ///   - serverPort: frps 端口（默认 7000）
    ///   - token:      frps 的 auth token
    ///   - stunServer: 打洞用的 STUN，**必须填国内可用的**
    ///   - proxyName:  被控端 frpc 里 `[[proxies]]` 的 name
    ///   - secretKey:  被控端那个 proxy 的 secretKey
    ///   - baseDir:    放日志/配置的目录（一般传 App 沙盒）
    ///   - preferredPort: 本机监听端口；不传就随机挑一个
    /// - Returns: 本机监听端口；失败返回 nil（原因见 FrpTunnel.lastError）
    ///
    /// ⚠️ 返回成功 **只代表 frpc 进程起来了**，隧道还在后台异步建立。
    ///    要等端口真的能连，用 SessionNetworking 的 waitForLocalPort。
    @discardableResult
    func start(serverAddr: String,
               serverPort: Int = 7000,
               token: String,
               stunServer: String = FrpTunnel.defaultStunServer,
               proxyName: String,
               secretKey: String,
               baseDir: String,
               preferredPort: Int32? = nil,
               keepTunnelOpen: Bool = true) -> Int32? {

        // ★ 无条件先停一次 —— 别只看自己的 isRunning 标志。
        //
        //   Swift 这边的状态和 Go 那边的 visitor 可能对不上（比如上次 stop 时
        //   Go 侧没完全释放），那样旧 visitor 还占着本机端口，新的就起不来，
        //   于是出现「App 报的端口 ≠ 实际监听的端口」这种错位。
        //   frp_stop_visitor 是幂等的，没在跑时调用无害。
        frp_stop_visitor()
        isRunning = false
        localPort = 0

        // 本机监听端口。
        //
        // ★ 优先级：上次用过的 > 调用方指定 > 随机。
        //   上次用过的排最前是刻意的 —— 调用方（SessionNetworking）是用
        //   findAvailablePort() 挑的，而那个只判断"现在空不空"：
        //   旧 visitor 没停干净时端口仍被自己占着，它会挑一个**不同的**端口，
        //   于是 App 报的端口和实际监听的端口错位（真机日志：报 20002、实际在 20000），
        //   scrcpy 对着没人听的端口死磕。复用同一个就不会错位。
        let port: Int32
        if lastUsedPort > 0 {
            port = lastUsedPort
        } else if let preferred = preferredPort {
            port = preferred
        } else {
            port = Int32(20000 + Int.random(in: 0..<4000))
        }

        // strdup 出来的 C 字符串要手动释放；用 defer 保证异常路径也不漏
        guard let cServer = strdup(serverAddr),
              let cToken = strdup(token),
              let cStun = strdup(stunServer),
              let cBase = strdup(baseDir),
              let cProxy = strdup(proxyName),
              let cSecret = strdup(secretKey) else {
            print("[FrpTunnel] ❌ strdup 失败")
            return nil
        }
        defer {
            free(cServer); free(cToken); free(cStun)
            free(cBase); free(cProxy); free(cSecret)
        }

        let rc = frp_start_visitor(
            cServer,
            Int32(serverPort),
            cToken,
            cStun,
            cBase,
            port,
            cProxy,
            cSecret,
            keepTunnelOpen ? 1 : 0
        )

        guard rc == 0 else {
            let err = statusString(frp_last_error())
            print("[FrpTunnel] ❌ 启动失败: \(err)")
            return nil
        }

        localPort = port
        // 记住这个端口 —— stop() 后重建时要复用它，避免和还在监听的旧 visitor 错位
        lastUsedPort = port
        isRunning = true
        currentProxyName = proxyName
        print("[FrpTunnel] ✅ visitor 已启动，本机端口 \(port)（proxy=\(proxyName)）")
        return port
    }

    /// 停掉当前隧道。
    func stop() {
        guard isRunning else { return }
        frp_stop_visitor()
        isRunning = false
        localPort = 0
        currentProxyName = ""
        print("[FrpTunnel] 已停止")
    }

    /// 这条隧道是不是已经在给同一个 proxy 跑了（跑着就不用重启，省一次打洞）。
    func isRunning(for proxyName: String) -> Bool {
        return isRunning && currentProxyName == proxyName && localPort > 0
    }

    /// 当前状态（给日志用）。
    var status: String {
        return statusString(frp_status())
    }

    /// 最后一次失败的原文（frp 自己的报错，比如 STUN 超时）。
    var lastErrorText: String {
        let text = statusString(frp_last_error())
        return text.isEmpty ? "(no error)" : text
    }

    /// 把 C 返回的 char* 取成 Swift String 并释放。
    private func statusString(_ ptr: UnsafeMutablePointer<CChar>?) -> String {
        guard let ptr = ptr else { return "(null)" }
        defer { frp_free(ptr) }
        return String(cString: ptr)
    }
}

/// frp 隧道的**全局**配置。
///
/// 每个被控手机有不同的 proxy 名（存在会话里），但 frps 地址 / token /
/// secretKey / STUN 这些是全局一份，所以放在这里读 UserDefaults
/// —— key 和 SettingsView 里 `AppSettings` 的 @AppStorage 完全一致。
struct FrpSettings {

    static let serverAddrKey = "settings.frp.server_addr"
    static let serverPortKey = "settings.frp.server_port"
    static let tokenKey      = "settings.frp.token"
    static let secretKeyKey  = "settings.frp.secret_key"
    static let stunServerKey = "settings.frp.stun_server"

    var serverAddr: String = ""
    var serverPort: Int = 7000
    var token: String = ""
    var secretKey: String = ""
    var stunServer: String = FrpTunnel.defaultStunServer

    static func load() -> FrpSettings {
        let defaults = UserDefaults.standard
        var settings = FrpSettings()

        settings.serverAddr = (defaults.string(forKey: serverAddrKey) ?? "")
            .trimmingCharacters(in: .whitespaces)
        settings.token = (defaults.string(forKey: tokenKey) ?? "")
            .trimmingCharacters(in: .whitespaces)
        settings.secretKey = (defaults.string(forKey: secretKeyKey) ?? "")
            .trimmingCharacters(in: .whitespaces)

        let portText = (defaults.string(forKey: serverPortKey) ?? "")
            .trimmingCharacters(in: .whitespaces)
        settings.serverPort = Int(portText) ?? 7000

        // ★ STUN 必须填国内可用的，留空就用实测可用的默认值
        let stun = (defaults.string(forKey: stunServerKey) ?? "")
            .trimmingCharacters(in: .whitespaces)
        settings.stunServer = stun.isEmpty ? FrpTunnel.defaultStunServer : stun

        return settings
    }

    /// 全局配置填全了没（frps 地址 + secretKey；token 允许为空 = frps 没开鉴权）。
    var isConfigured: Bool {
        return !serverAddr.isEmpty && !secretKey.isEmpty
    }

    /// 配置不全时返回给用户看的说明；齐全返回 nil。
    func validationError(proxyName: String) -> String? {
        if serverAddr.isEmpty {
            return "frp server address not set"
        }
        if secretKey.isEmpty {
            return "frp secret key not set"
        }
        if proxyName.isEmpty {
            return "frp proxy name not set"
        }
        return nil
    }
}

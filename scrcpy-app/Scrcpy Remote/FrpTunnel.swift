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

    /// 国内可用的 STUN 服务器（2026-09 实测）
    static let defaultStunServer = "stun.miwifi.com:3478"

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
    /// - Returns: 本机监听端口；失败返回 nil（原因见 FrpTunnel.lastError）
    @discardableResult
    func start(serverAddr: String,
               serverPort: Int = 7000,
               token: String,
               stunServer: String = FrpTunnel.defaultStunServer,
               proxyName: String,
               secretKey: String,
               baseDir: String,
               keepTunnelOpen: Bool = true) -> Int32? {

        if isRunning {
            stop()
        }

        // 挑一个本机空闲端口给 adb 连
        let port = Int32(20000 + Int.random(in: 0..<4000))

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
        isRunning = true
        print("[FrpTunnel] ✅ visitor 已启动，本机端口 \(port)（proxy=\(proxyName)）")
        return port
    }

    /// 停掉当前隧道。
    func stop() {
        guard isRunning else { return }
        frp_stop_visitor()
        isRunning = false
        localPort = 0
        print("[FrpTunnel] 已停止")
    }

    /// 当前状态（给日志用）。
    var status: String {
        return statusString(frp_status())
    }

    /// 把 C 返回的 char* 取成 Swift String 并释放。
    private func statusString(_ ptr: UnsafeMutablePointer<CChar>?) -> String {
        guard let ptr = ptr else { return "(null)" }
        defer { frp_free(ptr) }
        return String(cString: ptr)
    }
}

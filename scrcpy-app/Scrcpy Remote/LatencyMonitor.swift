//
//  LatencyMonitor.swift
//  Scrcpy Remote
//
//  连接成功后常驻测延迟 + 判断「当前走的是哪条路」，给界面那个小气泡用。
//
//  测量口径（别搞混，踩过坑）：
//    - 用的是 TCPLatencyTester（真 BSD socket：connect + send + recv），
//      **不是** ADBLatencyTester —— 后者每轮要起一个 adb 进程，光进程开销就 ~305ms，测出来没意义。
//    - 也不是 ICMP ping —— 息屏设备会延迟响应 ICMP，实测能 ping 出 92~202ms，
//      但 App 实际跑起来是流畅的（见项目 CLAUDE.md 的「测量教训」）。
//    - 走隧道时 connect 是连本机的 visitor listener（秒接），
//      所以读数 ≈ 纯隧道 RTT；局域网直连时 connect 本身要花一个 RTT，读数会偏高一档。
//
//  连接方式的判断：
//    - 局域网 / Tailscale / frp 由 SessionConnectionManager 的状态直接给出；
//    - frp 内部「P2P 还是中转」frp 没有运行时 API，只能读它自己写的
//      frpc_visitor.log：有 establishing nat hole connection successful 就是 P2P，
//      出现 make hole error / fallback 就是中转。
//

import Foundation
import Combine

/// 当前连接走的是哪条路
enum ConnectionKind: Equatable {
    case lan            // 同一局域网，直连（最快）
    case frpP2P         // frp XTCP 打洞成功，P2P 直连
    case frpRelay       // frp 没打通，经 frps 中转
    case tailscale      // 内置 tsnet
    case direct         // 其它直连（公网地址等）
    case unknown

    var label: String {
        switch self {
        case .lan:       return "局域网"
        case .frpP2P:    return "frp P2P"
        case .frpRelay:  return "frp 中转"
        case .tailscale: return "Tailscale"
        case .direct:    return "直连"
        case .unknown:   return "未知"
        }
    }

    /// 给界面用的排序权重（越靠前越快）
    var rank: Int {
        switch self {
        case .lan:       return 0
        case .frpP2P:    return 1
        case .tailscale: return 2
        case .frpRelay:  return 3
        case .direct:    return 4
        case .unknown:   return 5
        }
    }
}

@MainActor
final class LatencyMonitor: ObservableObject {

    static let shared = LatencyMonitor()

    /// 最近一次测得的往返延迟（毫秒）；nil = 还没测出来 / 测失败
    @Published private(set) var latencyMs: Double?
    /// 抖动（最近几次的标准差），没有足够样本时为 nil
    @Published private(set) var jitterMs: Double?
    /// 当前连接方式
    @Published private(set) var kind: ConnectionKind = .unknown

    /// 临时横幅（重连提示等）。
    ///
    /// ★ 为什么重连提示要放这儿：投屏画面是 SDL 建的**原生窗口**，盖在 SwiftUI 之上，
    ///   所以 `ConnectionStatusView` 那类 SwiftUI 状态界面在投屏期间**根本看不见**
    ///   （用户实测：重连时什么都看不到，只有卡住的画面）。
    ///   而气泡这个窗浮在 SDL 之上，是唯一能在这时候显示东西的地方。
    @Published private(set) var banner: String?

    func setBanner(_ text: String?) {
        banner = text
    }

    private var timer: Timer?
    private var samples: [Double] = []
    private let maxSamples = 6

    private init() {}

    // MARK: - 生命周期

    /// 连接成功后开始探测；重复调用是安全的。
    func start() {
        guard timer == nil else { return }
        refreshKind()
        probe()
        // 2 秒一次。别太密：每次探测都是一次真实的隧道请求。
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshKind()
                self?.probe()
            }
        }
    }

    /// 断开时停掉。
    func stop() {
        timer?.invalidate()
        timer = nil
        samples.removeAll()
        latencyMs = nil
        jitterMs = nil
        kind = .unknown
    }

    // MARK: - 探测

    private func probe() {
        let manager = SessionConnectionManager.shared
        guard let host = manager.actualHost,
              let portText = manager.actualPort,
              let port = UInt16(portText.trimmingCharacters(in: .whitespaces)) else {
            print("[LatencyMonitor] 还没有连接信息（host=\(manager.actualHost ?? "nil") port=\(manager.actualPort ?? "nil")），这次跳过")
            return
        }

        // 测量是阻塞的 socket 调用，丢到后台队列去，别占着主线程。
        // 用 LanDiscovery.measureRoundTrip 而不是工程里的 TCPLatencyTester ——
        // 后者等的是「对方回数据」，而 adbd 收到非协议字节只关连接、不回内容，
        // 实测每次都 "Failed to receive response"，气泡上的延迟一直出不来。
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let ms = LanDiscovery.measureRoundTrip(host: host, port: port, timeout: 3)
            DispatchQueue.main.async {
                guard let self else { return }
                if let ms {
                    print(String(format: "[LatencyMonitor] %@:%d -> %.1f ms", host, port, ms))
                    self.record(ms)
                } else {
                    // 打日志，别静默 —— 上一版就是静默 return，导致用户日志里
                    // 完全看不出延迟到底测没测、卡在哪一步。
                    print("[LatencyMonitor] 探测失败（\(host):\(port)）")
                }
            }
        }
    }

    private func record(_ ms: Double) {
        latencyMs = ms
        samples.append(ms)
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
        if samples.count >= 3 {
            let mean = samples.reduce(0, +) / Double(samples.count)
            let variance = samples.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(samples.count)
            jitterMs = variance.squareRoot()
        }
    }

    // MARK: - 判断连接方式

    private func refreshKind() {
        let manager = SessionConnectionManager.shared

        if manager.isUsingFrp {
            // frp 内部还要再分 P2P / 中转
            kind = frpKindFromLog() ?? .unknown
            return
        }
        if manager.isUsingTailscale {
            kind = .tailscale
            return
        }
        if let host = manager.actualHost, Self.isPrivateAddress(host) {
            kind = .lan
            return
        }
        kind = manager.actualHost == nil ? .unknown : .direct
    }

    /// 从 frp visitor 自己的日志里判断「P2P 还是中转」。
    ///
    /// 为什么读日志：frp 库没有暴露运行时状态，而 visitor 会把打洞结果写进
    /// `frpc_visitor.log` —— `establishing nat hole connection successful` 是 P2P，
    /// `make hole error` / fallback 就是走了中转。
    private func frpKindFromLog() -> ConnectionKind? {
        let logPath = (FrpTunnel.defaultBaseDir as NSString).appendingPathComponent("frpc_visitor.log")
        guard let tail = Self.readTail(path: logPath, maxBytes: 32 * 1024) else {
            return nil
        }

        // 只看最后一段：日志是追加写的，越靠后越接近当前状态。
        let recent = String(tail.suffix(6000))

        // 取「最后一次打洞结果」和「最后一次回退」谁更靠后
        let lastHole = recent.range(of: "nat hole connection successful", options: .backwards)
        let lastError = recent.range(of: "make hole error", options: .backwards)
        let lastFallback = recent.range(of: "fallback", options: .backwards)
            ?? recent.range(of: "Fallback", options: .backwards)

        var newest: (String.Index, ConnectionKind)?
        if let r = lastHole { newest = (r.lowerBound, .frpP2P) }
        if let r = lastError, newest == nil || r.lowerBound > newest!.0 { newest = (r.lowerBound, .frpRelay) }
        if let r = lastFallback, newest == nil || r.lowerBound > newest!.0 { newest = (r.lowerBound, .frpRelay) }

        return newest?.1
    }

    /// 读文件末尾若干字节（日志可能很大，别整个读进内存）。
    private static func readTail(path: String, maxBytes: Int) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? nil
        guard let data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 私网地址判断（局域网直连的判据）
    static func isPrivateAddress(_ host: String) -> Bool {
        if host.hasPrefix("127.") || host == "localhost" { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        if parts[0] == 10 { return true }
        if parts[0] == 192 && parts[1] == 168 { return true }
        if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
        if parts[0] == 169 && parts[1] == 254 { return true }
        return false
    }
}

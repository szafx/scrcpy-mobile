//
//  SessionConnectionManager.swift
//  Scrcpy Remote
//
//  Created by Ethan on 1/1/25.
//
//  断开连接处理逻辑：
//  - 所有断开连接都静默处理，不显示给用户
//  - 只记录日志用于调试
//
//  架构优化 (2025-01-01)：
//  - Action 执行逻辑已重构，通过 ScrcpyClientWrapper 进行任务透传
//  - VNC Actions 通过 ScrcpyClientWrapper.executeVNCActions 执行，确保上下文一致性
//  - ADB Actions 通过 ScrcpyClientWrapper.executeADB* 方法执行，支持设备序列号精确定位
//  - 避免使用单例 (shared instances)，防止异常情况和不必要的单例创建
//  - SessionConnectionManager 专注于连接管理和协调，所有执行任务通过 clientWrapper 透传
//  - 提高了代码的可维护性、可测试性和架构一致性

import Foundation
import Network
import UIKit
import ActivityKit

// MARK: - VNCQuickAction Extension

extension VNCQuickAction {
    /// 将 Swift 的 VNCQuickAction 枚举转换为 Objective-C 的 VNCQuickActionType
    /// - Returns: 对应的 VNCQuickActionType 原始值
    func toVNCQuickActionType() -> Int {
        switch self {
        case .inputKeys:
            return 0 // VNCQuickActionTypeInputKeys
        case .syncClipboard:
            return 1 // VNCQuickActionTypeSyncClipboard
        }
    }
}

// MARK: - VNCKeyModifier Extension

extension VNCKeyModifier {
    /// 将 VNC 键修饰符转换为对应的键码
    /// - Returns: VNC 键修饰符对应的键码
    func toVNCKeyCode() -> Int {
        switch self {
        case .ctrl:
            return 65507  // XK_Control_L (左 Ctrl)
        case .alt:
            return 65513  // XK_Alt_L (左 Alt)
        case .shift:
            return 65505  // XK_Shift_L (左 Shift)
        case .cmd:
            return 65515  // XK_Super_L (左 Super/Cmd)
        }
    }
}

// MARK: - Connection Callback Types

/// 连接状态回调闭包类型
/// - Parameters:
///   - status: 连接状态
///   - message: 状态消息
///   - isConnecting: 是否正在连接中
typealias ConnectionStatusCallback = (ScrcpyStatus, String?, Bool) -> Void

/// 连接错误回调闭包类型
/// - Parameters:
///   - title: 错误标题
///   - message: 错误消息
typealias ConnectionErrorCallback = (String, String) -> Void

/// Action 确认回调闭包类型
/// - Parameters:
///   - action: 需要确认的动作
///   - confirmCallback: 确认后的回调
typealias ActionConfirmationCallback = (ScrcpyAction, @escaping () -> Void) -> Void

/// 管理当前连接会话的状态
@objc class SessionConnectionManager: NSObject, ObservableObject {
    @objc static let shared = SessionConnectionManager()
    
    // MARK: - Connection State
    
    /// 当前连接的会话信息
    @objc @Published var currentSession: ScrcpySessionModel?
    
    /// 正在连接中的会话信息（用于在等待当前连接断开时临时保存）
    @Published var connectingSession: ScrcpySessionModel?
    
    /// 当前连接状态
    @Published var connectionStatus: ScrcpyStatus = ScrcpyStatusDisconnected
    
    /// 实际连接的主机地址（解析后的，可能通过 Tailscale 代理）
    @Published var actualHost: String?
    
    /// 实际连接的端口（解析后的，可能通过 Tailscale 代理）
    @Published var actualPort: String?
    
    /// 是否使用 Tailscale 连接
    @Published var isUsingTailscale: Bool = false

    /// 是否经内嵌 frp XTCP visitor 连接（具体走 P2P 还是中转见 LatencyMonitor）
    @Published var isUsingFrp: Bool = false
    
    /// Tailscale 本地转发端口（如果使用）
    @Published var tailscaleLocalPort: Int?
    
    /// 是否正在连接中
    @Published var isConnecting: Bool = false
    
    /// 当前连接的开始时间
    @Published var connectionStartTime: Date?
    
    // MARK: - Private Properties
    
    /// 当前连接的回调闭包
    private var currentConnectionCallback: ConnectionStatusCallback?
    
    /// 当前错误回调闭包
    private var currentErrorCallback: ConnectionErrorCallback?

    /// 最近一次连接用的回调 —— **专门留给重连复用**。
    ///
    /// ★ 为什么不直接用 currentConnectionCallback：那个在连接成功/失败后会被
    ///   `cleanupCallbacksAfterSuccess` / `...Failure` 清成 nil（它本来就是给
    ///   连接过程用的，用完即弃）。可重连发生在**连接成功之后**（用着用着网断了），
    ///   那时它早就是 nil 了。
    ///
    ///   实测日志就是这么卡住的：
    ///     [AutoReconnect] 网络路径变化：可用，接口 [pdp_ip0]
    ///     [AutoReconnect] 没有可复用的回调，跳过自动重连     ←★
    ///   结果是切网之后永远不恢复，用户只看到画面冻结。
    private var reusableStatusCallback: ConnectionStatusCallback?
    private var reusableErrorCallback: ConnectionErrorCallback?

    // MARK: - 网络变化 → 自动重连（相关状态）

    /// 监听网络路径变化：切 WiFi、切蜂窝、掉线重连都会触发
    private let pathMonitor = NWPathMonitor()
    /// 待执行的重连检查（网络抖动时会被取消重排）
    private var pendingReconnectCheck: DispatchWorkItem?
    /// 这次「连接」是自动重连发起的。
    ///
    /// 用途：让 connectToSession 跳过开头的「先 disconnectCurrent()」那步 ——
    /// 那一步会 clearCurrentSession() 把界面踢回主页，而重连是要**原地**重建，
    /// 会话不该被清掉（用户明确要求：「不该回主页，应该留在连接界面重连」）。
    private var isReconnecting = false

    /// 自动重连进行中（避免叠加触发）。
    ///
    /// ★ 对外可见：MainContentView 要据此把「正在连接」那个界面显示出来。
    ///   不暴露的话，断连瞬间 connectionStatus 是 Disconnected，
    ///   而连接界面的显示条件里有 `connectionStatus != Disconnected` ——
    ///   于是界面不显示、卡在投屏页面上（用户实测：「切换就卡在投屏页面」）。
    @Published private(set) var isAutoReconnecting = false
    /// 上次重连的时刻 —— 用来冷却，避免切网时连着抖几下、重连被触发多次。
    ///
    /// 注意触发点已经收紧到「网络变化 → 断开」这一条路了（见 Disconnected 处理器），
    /// 不会再有「失败后又重连」的循环，所以这个值不用设太大 ——
    /// 设大了反而让用户觉得"切完网半天没反应"。
    private var lastReconnectAt: Date?
    private let reconnectCooldown: TimeInterval = 5
    /// 网络切换常常连着抖几下（WiFi→无网→蜂窝），等一下让它稳定再动手。
    ///
    /// 但**别太长** —— 这段等待里画面是冻结的、菜单点什么都没反应，
    /// 用户看起来就是"卡住"。实测反馈：「页面卡住，过一会自动退回主页」。
    private let reconnectDebounce: TimeInterval = 1.5
    
    /// 当前 Action 确认回调闭包
    private var currentActionConfirmationCallback: ActionConfirmationCallback?
    
    /// 当前等待确认的动作和回调
    private var pendingConfirmationAction: ScrcpyAction?
    private var pendingConfirmationCallback: (() -> Void)?
    
    /// Scrcpy 客户端包装器实例，用于直接管理连接
    private var scrcpyClientWrapper: ScrcpyClientWrapper?

    /// 当前正在跑的连接任务。
    ///
    /// ★ 必须能取消：用户中途点取消时，如果放任它继续跑，它会一直 await
    ///   （局域网扫描 / frp 打洞都可能要好几秒），回来之后又把状态改一遍 ——
    ///   结果是导航栏那两个按钮因为 isConnecting 还是 true 而一直灰着点不动，
    ///   再点连接也会被这个残留任务搅乱。取消掉就干净了。
    private var connectionTask: Task<Void, Never>?
    
    /// 后台断开连接计时器
    private var backgroundDisconnectTimer: Timer?

    /// Live Activity 管理器
    private lazy var liveActivityManager: Any? = {
        if #available(iOS 16.1, *) {
            return ScrcpyLiveActivityManager.shared
        } else {
            return nil
        }
    }()

    /// 用于存储上次连接会话的 UserDefaults key
    private let lastSessionKey = "session_connection_manager.last_session"
    
    override private init() {
        super.init()
        setupNotificationObservers()
        setupPathMonitor()
    }
    
    // MARK: - Notification Observers
    
    private func setupNotificationObservers() {
        // 监听 scrcpy 状态更新
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScrcpyStatusUpdate(_:)),
            name: Notification.Name("ScrcpyStatusUpdated"),
            object: nil
        )
        
        // 监听应用进入后台
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleApplicationDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        
        // 监听应用即将进入前台（比 didBecomeActive 更早），尽早清除后台标志
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleApplicationWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )

        // 监听应用变为活跃
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleApplicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    @objc private func handleApplicationWillEnterForeground() {
        // Earliest foreground signal — clear the background flag right away.
        SetApplicationBackgroundState(false)
    }

    // MARK: - 网络变化 → 自动重连

    /// 起一个网络路径监听器。
    ///
    /// 为什么必须有它：**切网（WiFi↔蜂窝）会让已建立的 TCP 连接全部作废**，
    /// 因为源地址变了、对端不再认得这条连接。这一步跟走局域网还是隧道无关 ——
    /// frp 会重建自己的隧道、tsnet 也会重连，但**上面那层 adb 连接**断了就是断了。
    /// 没有这个监听的话，画面会**静默卡死**，用户只能自己断开重连。
    private func setupPathMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            // ★ 无论当前有没有活动连接，都要把最新的路径状态喂给 LanDiscovery。
            //   不然「开着 WiFi 进 App、之后再切网」时，判断依据会一直是旧的 ——
            //   这正是用户反馈的「App 没法实时识别 WiFi 和蜂窝状态」。
            LanDiscovery.updatePath(path)

            DispatchQueue.main.async {
                self?.handlePathChange(path)
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.scrcpy.pathmonitor"))
    }

    private func handlePathChange(_ path: NWPath) {
        let interfaces = path.availableInterfaces.map { $0.name }.joined(separator: ",")
        print("[AutoReconnect] 网络路径变化：\(path.status == .satisfied ? "可用" : "不可用")，接口 [\(interfaces)]")

        // ★★ 这里**只打标记，不做判断、不直接重连**。
        //
        //   为什么：实测**断开通知比路径变化先到** ——
        //     1. 网络一变 → 底层连接立刻断 → 发 Disconnected 通知（先把状态改掉、会话清掉）
        //     2. pathUpdateHandler 这时才到，此时 connectionStatus 已经是 Disconnected、
        //        currentSession 也可能已经 nil 了
        //   所以任何基于「当前状态」的判断（比如「必须 == Connected」）都会永远失效 ——
        //   上一版就是这么改的，结果一次都不重连了。
        //
        //   正确做法：网络变化只负责**留个记号**，真正决定要不要重连的是
        //   随后的 Disconnected 处理器 —— 那时它手里还有「刚才连着的会话」。
        // ★ 打标记**不设任何前置条件** —— 网络变了就是变了，照记不误。
        //
        //   之前这里有个 `guard currentSession != nil`，造成了环形依赖：
        //     切网 → 底层断 → Disconnected 处理器先把会话清掉
        //          → pathUpdateHandler 才到，此时 currentSession 已 nil → 被 guard 拦掉
        //          → 标记永远设不上 → 断开处理器收不到标记 → 不重连 → 回主页
        //   真机日志实锤：切 WiFi 那次日志里**完全没有**「网络路径变化」这行。
        //
        //   标记本身有时效（15 秒）兜底，所以放宽了也不会误伤 ——
        //   手动断开时这个标记早就过期了。
        justHadNetworkChange = true
        justHadNetworkChangeAt = Date()
    }

    /// 网络刚刚变化过（断开处理器据此决定要不要自动重连）。
    private var justHadNetworkChange = false
    private var justHadNetworkChangeAt: Date?
    /// 网络变化的有效期 —— 太久之前的切换不该用来解释现在的断开。
    private let networkChangeWindow: TimeInterval = 15

    /// 网络变化是否还「新鲜」（在有效窗口内）。
    private var hasRecentNetworkChange: Bool {
        guard justHadNetworkChange, let at = justHadNetworkChangeAt else { return false }
        return Date().timeIntervalSince(at) < networkChangeWindow
    }

    private var justDisconnectedFromNetwork = false

    /// 网络路径变了 → 直接重连。
    ///
    /// ★★ 这里**故意不做「还通不通」的探测**，这是个踩过的坑：
    ///
    ///   TCP 连接是**绑定源地址**的，切网（WiFi↔蜂窝）之后旧连接**必然作废**，
    ///   本来就不需要探测。而之前那版会先探一次，问题是**探测的时机太早** ——
    ///   那一刻 frp 隧道还没断透，本地 listener 仍然接受连接，于是判成
    ///   「还通、保持不动」。可等它真断的时候已经没有后续探测了，
    ///   App 就**永远不知道断了**：画面冻结、什么都不响应、也走不到「正在重连」。
    ///
    ///   用户实测就是这个：「两次连接状态下蜂窝和 wifi 的切换都没有看到
    ///   正在重连这个东西」，日志里则是连着几条
    ///   `网络变了但连接还通，保持不动`。
    ///
    ///   所以现在：路径变化 = 连接作废 = 直接重连。
    ///   重连会重新走完整判定（WiFi 下回局域网、蜂窝下落 frp），不会连错。
    private func verifyConnectionAndReconnectIfNeeded() {
        guard !isAutoReconnecting, let session = currentSession else { return }
        performAutoReconnect(session)
    }

    private func performAutoReconnect(_ session: ScrcpySessionModel) {
        guard !isAutoReconnecting else { return }

        // 冷却：切网会连着报好几次路径变化，而一次重连要几十秒 ——
        // 没有这个就会被反复触发，变成「重连 → 失败 → 再重连」的死循环。
        if let last = lastReconnectAt, Date().timeIntervalSince(last) < reconnectCooldown {
            let left = Int(reconnectCooldown - Date().timeIntervalSince(last))
            print("[AutoReconnect] 距上次重连不到 \(Int(reconnectCooldown)) 秒（还差 \(left)s），跳过")
            return
        }
        lastReconnectAt = Date()

        // 已经在连接中就别再发起一次（重连流程本身会走到 connectToSession）
        if isConnecting {
            print("[AutoReconnect] 正在连接中，跳过重复触发")
            return
        }

        // 用**专门留给重连的那份**回调 —— currentConnectionCallback 在连接成功后
        // 已经被 cleanupCallbacksAfterSuccess 清成 nil 了，
        // 拿它判断会永远走到「没有可复用的回调，跳过自动重连」。
        guard let statusCallback = reusableStatusCallback,
              let errorCallback = reusableErrorCallback else {
            print("[AutoReconnect] 没有可复用的回调，跳过自动重连")
            return
        }

        isAutoReconnecting = true
        print("[AutoReconnect] 连接已断（网络切换导致），自动重连…")
        statusCallback(ScrcpyStatusConnecting, "网络已切换，正在重连…", true)

        // 注意：这里**不再往气泡上写提示**。
        // 用户指出的对：重连就该回到「正在连接」那个界面上进行 ——
        // 它本来就有进度提示和 Dismiss 按钮，气泡上再挂一条是画蛇添足。
        // （之前那么做是因为误判了「SwiftUI 界面被 SDL 挡住」，
        //   实际原因连接界面压根没被要求显示，见 MainContentView 里
        //   shouldShowConnectionStatusView 的 isAutoReconnecting 分支。）

        // ★ 用重连专用的拆解 —— 保留会话，UI 就留在连接界面上原地重连，
        //   而不是被 clearCurrentSession() 踢回主页（用户明确要求的行为）。
        teardownConnectionForReconnect()
        //
        // 重连会重新走一遍「局域网优先、否则隧道」的判定 ——
        // 所以 WiFi 走到蜂窝会自动落到 frp，走回来又会自动回到局域网。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            self.isAutoReconnecting = false
            // 标记这次连接来自自动重连 —— connectToSession 据此跳过「先断开」那步，
            // 免得又调 clearCurrentSession() 把界面踢回主页。
            self.isReconnecting = true
            self.connectToSession(session, statusCallback: statusCallback, errorCallback: errorCallback)
        }
    }
    
    @objc private func handleScrcpyStatusUpdate(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let statusValue = userInfo["status"] as? Int else {
            print("⚠️ [SessionConnectionManager] Invalid notification: \(notification)")
            return
        }
        
        let statusMessage = userInfo["message"] as? String
        print("🔔 [SessionConnectionManager] Received status update: \(statusValue) from notification")
        
        DispatchQueue.main.async {
            let newStatus = ScrcpyStatus(UInt32(statusValue))
            self.connectionStatus = newStatus
            
            switch newStatus {
            case ScrcpyStatusConnecting:
                print("🔄 [SessionConnectionManager] Status: Connecting")
                self.isConnecting = true
                
            case ScrcpyStatusSDLWindowAppeared:
                print("✅ [SessionConnectionManager] Status: SDL Window Appeared")
                self.isConnecting = false

                // 记录连接开始时间
                if self.connectionStartTime == nil {
                    self.connectionStartTime = Date()
                    print("⏰ [SessionConnectionManager] Connection start time recorded: \(self.connectionStartTime!)")
                }

                // 启用后台保活的静音音频（在 SDL audio session 起来之后,
                // 我们用 .playback + .mixWithOthers 覆盖,与 scrcpy/VNC 音频共存）。
                BackgroundKeepAliveManager.shared.sessionConnected()

                // 连接成功后,如果启用了自动重连,保存当前会话
                self.saveCurrentSessionIfAutoReconnectEnabled()

                // 执行待执行的动作
                self.executePendingActionIfNeeded()

                // 连接成功后，延迟清理回调以避免 ConnectionStatusView 在后台运行
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.cleanupCallbacksAfterSuccess()
                }

            case ScrcpyStatusSDLWindowCreated:
                print("✅ [SessionConnectionManager] Status: SDL Window Created")
                self.isConnecting = false

                // 记录连接开始时间
                if self.connectionStartTime == nil {
                    self.connectionStartTime = Date()
                    print("⏰ [SessionConnectionManager] Connection start time recorded: \(self.connectionStartTime!)")
                }

                BackgroundKeepAliveManager.shared.sessionConnected()

                // 连接成功后,如果启用了自动重连,保存当前会话
                self.saveCurrentSessionIfAutoReconnectEnabled()

                // 延迟执行待执行的动作，确保界面完全显示
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    print("⏰ [SessionConnectionManager] Window created delay completed, executing pending action")
                    self.executePendingActionIfNeeded()
                }

                // 连接成功后，延迟清理回调以避免 ConnectionStatusView 在后台运行
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.cleanupCallbacksAfterSuccess()
                }
                
            case ScrcpyStatusDisconnected:
                print("❌ [SessionConnectionManager] Status: Disconnected - clearing session")
                if let disconnectMessage = statusMessage, !disconnectMessage.isEmpty {
                    print("ℹ️ [SessionConnectionManager] Disconnect message: \(disconnectMessage)")
                }

                // ★★ 决定要不要自动重连，**就在这一步**（而不是网络变化的回调里）。
                //
                //   为什么是这里：实测**断开通知比网络路径变化先到** ——
                //   等到 pathUpdateHandler 触发时，状态已经变成 Disconnected、
                //   会话也可能被清掉了，那时再想判断「刚才是不是连着」已经没依据。
                //   而这个处理器手里正好有刚断掉的会话，是最好的判断时机。
                //
                //   判据是「最近刚发生过网络变化」：网络切换导致的断开才值得重连；
                //   用户手动断开、或者连接本来就失败，都不该自动重连
                //   （否则就是「失败 → 回主页 → 自动重连 → 又失败」的死循环）。
                // ★★ 先排除「用户主动断开」。
                //
                //   菜单里的「关闭连接」**不经过 disconnectCurrent()** ——
                //   它是 App 内部直接断开的，只发一条 Disconnected 通知。
                //   所以在那儿清标记没用（第一次就是这么修的，没生效）。
                //
                //   可靠的判据是断开消息本身：用户主动断开时它是
                //   "User disconnected from ADB client"（真机日志实锤）。
                let userInitiated = disconnectMessage?.localizedCaseInsensitiveContains("user disconnected") == true
                if userInitiated {
                    print("[AutoReconnect] 用户主动断开 —— 不重连，清掉网络变化标记")
                    self.justHadNetworkChange = false
                    self.justHadNetworkChangeAt = nil
                }

                if self.hasRecentNetworkChange, !userInitiated,
                   !self.isAutoReconnecting, !self.isConnecting {
                    self.justHadNetworkChange = false      // 用掉就清，别影响下一次判断
                    if let session = self.currentSession {
                        print("[AutoReconnect] 因网络切换而断开 —— 自动重连（保留会话，不回主页）")
                        // 先弹提示，让用户知道发生了什么
                        if let cb = self.reusableStatusCallback {
                            cb(ScrcpyStatusConnecting, "网络已切换，正在重连…", true)
                        }
                        self.performAutoReconnect(session)
                        break
                    }
                    print("[AutoReconnect] 网络变过但没有可用会话，跳过")
                }

                // Check for ERROR in the last output and show alert if found
                self.checkForErrorsAndShowAlert()

                self.isConnecting = false

                // ★ 自动重连期间**绝不清会话** —— 否则界面立刻回主页。
                //   （走到这儿说明是上面那条分支之外的路径，保险再判一次。）
                if self.isAutoReconnecting {
                    print("[AutoReconnect] 重连期间收到 Disconnected —— 保留会话，不回主页")
                    break
                }

                // 如果正在执行带 action 的连接，不清除 pendingAction
                self.clearCurrentSession(clearPendingAction: !self.isConnectingWithAction)
                
            case ScrcpyStatusConnectingFailed:
                print("❌ [SessionConnectionManager] Status: Connection Failed")
                self.isConnecting = false

                // ★ 局域网直连失败 → 自动改走隧道再试一次。
                //
                //   局域网那条路有个**竞态**：存活验证通过之后、真正连上之前，
                //   WiFi 可能刚好断掉。用户实测就是这种 —— 日志里
                //   「用这个会话上次的地址」之后紧接着就是直连失败。
                //   这种失败不该让用户手动重试：隧道本来就能通。
                //
                //   只回落一次（skipLANOnNextAttempt 会让下次连接跳过局域网那一级），
                //   避免失败-回落-再失败来回循环。
                if SessionNetworking.shared.lastAttemptWasLAN, !self.isAutoReconnecting {
                    print("[AutoReconnect] 局域网直连失败 —— 自动改走隧道重试一次")
                    SessionNetworking.shared.skipLANOnNextAttempt()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        guard let self, let session = self.currentSession else { return }
                        self.performAutoReconnect(session)
                    }
                }

                // 错误信息现在通过状态回调传递到 ConnectionStatusView，不再调用错误回调
                if let errorMessage = statusMessage, !errorMessage.isEmpty {
                    print("📝 [SessionConnectionManager] Error message: \(errorMessage)")
                } else {
                    print("📝 [SessionConnectionManager] No specific error message, using default")
                }
                
                // 连接失败后，不自动清理，等待用户主动 dismiss
                // 只清理回调以避免重复调用
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.cleanupCallbacksAfterFailure()
                }
                
            default:
                print("🔄 [SessionConnectionManager] Status update: \(statusValue)")
            }
            
            // 调用状态回调
            if let callback = self.currentConnectionCallback {
                callback(newStatus, statusMessage, self.isConnecting)
            }
            
            // 更新 Live Activity
            self.updateLiveActivityIfNeeded(status: newStatus, message: statusMessage)
        }
    }
    
    @objc private func handleApplicationDidEnterBackground() {
        // Set the background flag synchronously, before anything else. The
        // VideoToolbox decode session dies the instant we background, and the
        // decoder thread can hit avcodec_receive_frame's error path within a
        // few ms. BackgroundKeepAlive.evaluate() also sets this, but it runs
        // async via Combine (.receive(on:)) — too late. This direct @objc
        // observer fires synchronously when iOS posts the notification.
        SetApplicationBackgroundState(true)

        print("📱 [SessionConnectionManager] ========================================")
        print("📱 [SessionConnectionManager] Application did enter background")
        print("📱 [SessionConnectionManager] ========================================")

        // 打印当前连接状态
        print("📊 [SessionConnectionManager] Current connection status:")
        print("   - Connection status: \(connectionStatus.description)")
        print("   - Is active: \(connectionStatus.isActive)")
        print("   - Is connecting: \(isConnecting)")
        print("   - Current session: \(currentSession?.sessionName ?? "nil")")

        // 如果启用了自动重连并且当前有活跃连接，保存当前会话
        let autoReconnectEnabled = UserDefaults.standard.bool(forKey: "settings.auto_reconnect.enabled")
        print("⚙️ [SessionConnectionManager] Auto reconnect enabled: \(autoReconnectEnabled)")

        if autoReconnectEnabled && connectionStatus.isActive, let session = currentSession {
            print("💾 [SessionConnectionManager] Re-saving current session on background...")
            print("   - Session name: \(session.sessionName)")
            print("   - Session host: \(session.hostReal)")
            print("   - Session port: \(session.port)")
            print("   - Device type: \(session.deviceType.rawValue)")
            saveLastSession(session)
            print("✅ [SessionConnectionManager] Session re-saved on background (backup)")
        } else {
            if !autoReconnectEnabled {
                print("⏭️ [SessionConnectionManager] Auto reconnect is disabled, skipping session save")
            } else if !connectionStatus.isActive {
                print("⏭️ [SessionConnectionManager] No active connection, skipping session save")
            } else {
                print("⏭️ [SessionConnectionManager] No current session, skipping session save")
            }
        }

        // 如果当前有活跃连接，启动 Live Activity
        startLiveActivityIfNeeded()

        // 若无活跃连接但仍存在旧的 Live Activity，则停止它，避免卡住
        if #available(iOS 16.1, *),
           let manager = liveActivityManager as? ScrcpyLiveActivityManager,
           manager.hasActiveActivity,
           !connectionStatus.isActive {
            print("🧹 [SessionConnectionManager] No active connection; stopping stale Live Activity in background")
            manager.stopActivity()
        }

        // 启动后台断开计时器
        startBackgroundDisconnectTimer()

        print("📱 [SessionConnectionManager] ========================================")
        print("📱 [SessionConnectionManager] Background handling completed")
        print("📱 [SessionConnectionManager] ========================================")
    }

    @objc private func handleApplicationDidBecomeActive() {
        // Clear the background flag synchronously and as early as possible, so
        // a genuine decode error right after foregrounding is not wrongly
        // suppressed as a background VT-session loss.
        SetApplicationBackgroundState(false)

        print("📱 [SessionConnectionManager] ========================================")
        print("📱 [SessionConnectionManager] Application did become active")
        print("📱 [SessionConnectionManager] ========================================")

        // 打印当前连接状态
        print("📊 [SessionConnectionManager] Current connection status:")
        print("   - Connection status: \(connectionStatus.description)")
        print("   - Is active: \(connectionStatus.isActive)")
        print("   - Is connecting: \(isConnecting)")
        print("   - Current session: \(currentSession?.sessionName ?? "nil")")

        // 取消后台断开计时器
        stopBackgroundDisconnectTimer()

        // 检查是否需要自动重连
        print("🔍 [SessionConnectionManager] Checking if auto reconnect is needed...")
        attemptAutoReconnectIfNeeded()

        print("📱 [SessionConnectionManager] ========================================")
        print("📱 [SessionConnectionManager] Foreground handling completed")
        print("📱 [SessionConnectionManager] ========================================")
    }

    // MARK: - Background Task Management

    private func startBackgroundDisconnectTimer() {
        guard connectionStatus.isActive, backgroundDisconnectTimer == nil else {
            return
        }

        let duration = AppSettings().backgroundActiveDuration
        guard let timeInterval = duration.seconds else {
            print("后台保持连接设置为永久，不启动断开计时器")
            return
        }

        print("Start the background disconnection timer, will disconnect after \(duration.rawValue)")

        backgroundDisconnectTimer = Timer.scheduledTimer(withTimeInterval: timeInterval, repeats: false) { [weak self] _ in
            print("后台时间到，断开连接")
            self?.disconnectCurrent()
        }
    }

    private func stopBackgroundDisconnectTimer() {
        if backgroundDisconnectTimer != nil {
            print("取消后台断开计时器")
            backgroundDisconnectTimer?.invalidate()
            backgroundDisconnectTimer = nil
        }
    }
    
    // MARK: - Connection Management
    
    /// 当前要执行的动作
    private var pendingAction: ScrcpyAction?
    
    /// 是否正在执行带 action 的连接（防止在重连过程中清除 pendingAction）
    private var isConnectingWithAction: Bool = false
    
    /// 是否已经执行过 pendingAction（防止重复执行）
    private var hasExecutedPendingAction: Bool = false
    
    /// 连接到指定会话
    /// - Parameters:
    ///   - session: 要连接的会话模型
    ///   - statusCallback: 连接状态回调
    ///   - errorCallback: 错误回调
    func connectToSession(
        _ session: ScrcpySessionModel,
        statusCallback: @escaping ConnectionStatusCallback,
        errorCallback: @escaping ConnectionErrorCallback
    ) {
        print("🚀 [SessionConnectionManager] Starting connection to session: \(session.sessionName)")
        
        // 保存将要连接的会话信息
        connectingSession = session
        
        // 保存回调闭包
        currentConnectionCallback = statusCallback
        currentErrorCallback = errorCallback
        // 另存一份给重连用（上面那两个连接结束会被清掉，见 reusableStatusCallback 的说明）
        reusableStatusCallback = statusCallback
        reusableErrorCallback = errorCallback
        
        // ★ 读取后立刻复位 —— 这个标记只对本次连接有效，
        //   免得影响用户之后手动发起的连接（那一次是**应该**先断开的）。
        let fromAutoReconnect = isReconnecting
        isReconnecting = false

        // 如果当前状态不是 Disconnected，先断开现有连接。
        //
        // ★ 但**自动重连发起的这次不行** —— 那个 disconnectCurrent() 会调
        //   clearCurrentSession()，把 currentSession 清掉、UI 直接回主页。
        //   而重连刚在上一步用 teardownConnectionForReconnect() 原地拆过了，
        //   这里再拆一次既多余、又会把用户从连接界面踢走。
        if connectionStatus != ScrcpyStatusDisconnected, !fromAutoReconnect {
            print("🔄 [SessionConnectionManager] Current status is \(connectionStatus.description), disconnecting first")
            disconnectCurrent()

            // 等待断开完成后再开始新连接
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.performConnection(to: session, statusCallback: statusCallback, errorCallback: errorCallback)
            }
        } else {
            // 直接开始连接
            performConnection(to: session, statusCallback: statusCallback, errorCallback: errorCallback)
        }
    }
    
    /// 连接到指定会话并执行动作
    /// - Parameters:
    ///   - session: 要连接的会话模型
    ///   - action: 要执行的动作
    ///   - statusCallback: 连接状态回调
    ///   - errorCallback: 错误回调
    ///   - actionConfirmationCallback: Action 确认回调（可选）
    @objc func connectToSessionWithAction(
        _ session: ScrcpySessionModel,
        action: ScrcpyAction,
        statusCallback: @escaping ConnectionStatusCallback,
        errorCallback: @escaping ConnectionErrorCallback,
        actionConfirmationCallback: ActionConfirmationCallback? = nil
    ) {
        print("🚀 [SessionConnectionManager] Starting connection with action: \(action.name) to session: \(session.sessionName)")
        print("📝 [SessionConnectionManager] Action details - Type: \(action.deviceType), Timing: \(action.executionTiming)")
        
        // 设置标志和保存要执行的动作
        isConnectingWithAction = true
        hasExecutedPendingAction = false
        pendingAction = action
        currentActionConfirmationCallback = actionConfirmationCallback
        print("💾 [SessionConnectionManager] Pending action saved: \(action.name)")
        
        // 调用原有的连接方法
        connectToSession(session, statusCallback: statusCallback, errorCallback: errorCallback)
    }
    
    /// 在当前会话上直接执行动作，不需要重新连接
    /// - Parameters:
    ///   - action: 要执行的动作
    ///   - statusCallback: 连接状态回调
    ///   - errorCallback: 错误回调
    ///   - actionConfirmationCallback: Action 确认回调（可选）
    @objc func executeActionOnCurrentSession(
        _ action: ScrcpyAction,
        statusCallback: @escaping ConnectionStatusCallback,
        errorCallback: @escaping ConnectionErrorCallback,
        actionConfirmationCallback: ActionConfirmationCallback? = nil
    ) {
        print("🎯 [SessionConnectionManager] Executing action on current session: \(action.name)")
        
        guard let currentSession = currentSession else {
            print("❌ [SessionConnectionManager] Cannot execute action: no current session")
            errorCallback("No Active Session", "No active session found. Please connect to a device first.")
            return
        }
        
        guard connectionStatus.isActive else {
            print("❌ [SessionConnectionManager] Cannot execute action: session not active (status: \(connectionStatus))")
            errorCallback("Session Not Active", "Current session is not active. Please ensure the connection is established.")
            return
        }
        
        print("✅ [SessionConnectionManager] Current session is connected, executing action immediately")
        statusCallback(ScrcpyStatusConnected, "Executing action on current session", false)
        
        // 根据动作的执行时机决定如何执行
        switch action.executionTiming {
        case .immediate:
            print("⚡ [SessionConnectionManager] Executing action immediately on current session")
            executeAction(action)
            statusCallback(ScrcpyStatusConnected, "Action executed successfully", false)
        case .delayed:
            print("⏰ [SessionConnectionManager] Executing action after \(action.delaySeconds) seconds delay on current session")
            statusCallback(ScrcpyStatusConnected, "Action will execute in \(action.delaySeconds) seconds", false)
            DispatchQueue.main.asyncAfter(deadline: .now() + TimeInterval(action.delaySeconds)) {
                self.executeAction(action)
                statusCallback(ScrcpyStatusConnected, "Action executed successfully", false)
            }
        case .confirmation:
            print("❓ [SessionConnectionManager] Action requires confirmation on current session")
            if let confirmationCallback = actionConfirmationCallback {
                confirmationCallback(action) { [weak self] in
                    print("✅ [SessionConnectionManager] User confirmed action, executing on current session")
                    self?.executeAction(action)
                    statusCallback(ScrcpyStatusConnected, "Action executed successfully", false)
                }
            } else {
                print("⚠️ [SessionConnectionManager] No confirmation callback, executing directly on current session")
                executeAction(action)
                statusCallback(ScrcpyStatusConnected, "Action executed successfully", false)
            }
        }
    }
    
    /// 执行实际的连接逻辑
    /// - Parameters:
    ///   - session: 要连接的会话模型
    ///   - statusCallback: 连接状态回调
    ///   - errorCallback: 错误回调
    private func performConnection(
        to session: ScrcpySessionModel,
        statusCallback: @escaping ConnectionStatusCallback,
        errorCallback: @escaping ConnectionErrorCallback
    ) {
        print("🔗 [SessionConnectionManager] Performing connection to session: \(session.sessionName)")

        isConnecting = true
        statusCallback(ScrcpyStatusConnecting, "Preparing connection...", true)

        // Hook up SessionNetworking status callback for Tailscale/OAuth status updates
        SessionNetworking.shared.statusUpdateCallback = { [weak self] message in
            DispatchQueue.main.async {
                print("📡 [SessionConnectionManager] Network status: \(message)")
                statusCallback(ScrcpyStatusConnecting, message, true)
            }
        }

        // 上一轮如果还没结束（用户连点、或上次取消得不干净），先把它停掉
        connectionTask?.cancel()
        connectionTask = Task {
            do {
                var connectionInfo = await SessionNetworking.shared.getConnectionInfo(for: session)

                // 用户中途取消了就别再往下改状态了
                if Task.isCancelled {
                    print("🚫 [SessionConnectionManager] 连接任务已取消，放弃本次连接")
                    return
                }
                
                // 如果是 Tailscale / frp 连接且首次获取信息失败，则重试一次
                // 仅当隧道本身没建起来时重试（地址填错的话重试也没用，但值得再试一次打洞）
                if connectionInfo == nil && (session.useTailscale || session.useFrp) {
                    print("⚠️ [SessionConnectionManager] Failed to get tunnel connection info, retrying once...")
                    
                    // 停止当前转发并等待
                    _ = SessionNetworking.shared.stopForwarding(for: session.id)
                    try await Task.sleep(nanoseconds: 1_000_000_000) // 1秒
                    
                    // 再次尝试获取连接信息
                    connectionInfo = await SessionNetworking.shared.getConnectionInfo(for: session)
                }
                
                guard let finalConnectionInfo = connectionInfo else {
                    await MainActor.run {
                        // Clear the status callback on error
                        SessionNetworking.shared.statusUpdateCallback = nil
                        self.handleConnectionError(
                            title: "Connection Setup Failed",
                            message: "Failed to setup connection. Please check your network configuration and try again.",
                            errorCallback: errorCallback
                        )
                    }
                    return
                }
                
                print("📍 [SessionConnectionManager] Connection info obtained: \(finalConnectionInfo.description)")
                
                await MainActor.run {
                    self.setCurrentSession(session, connectionInfo: finalConnectionInfo)
                    
                    var sessionDict = session.toDict()
                    sessionDict["hostReal"] = finalConnectionInfo.host
                    sessionDict["port"] = finalConnectionInfo.port
                    
                    if finalConnectionInfo.isUsingTailscale {
                        // Carry the real remote target through so a failed local
                        // forward can produce a Tailscale-aware error instead of
                        // the misleading "accept the adb authorization" tip.
                        sessionDict["isUsingTailscale"] = true
                        sessionDict["tailscaleRemoteHost"] = finalConnectionInfo.originalHost
                        sessionDict["tailscaleRemotePort"] = finalConnectionInfo.originalPort
                        print("🔗 [SessionConnectionManager] Using Tailscale connection: \(finalConnectionInfo.originalHost):\(finalConnectionInfo.originalPort) -> \(finalConnectionInfo.host):\(finalConnectionInfo.port)")
                    } else if finalConnectionInfo.isUsingFrp {
                        // frp 隧道：hostReal 已经指向 127.0.0.1:<本机端口>（上面那行设过了）。
                        // 把真实目标带上，失败时能给出有针对性的提示而不是
                        // 那句容易误导的「去手机上点允许 USB 调试」。
                        sessionDict["isUsingFrp"] = true
                        sessionDict["frpRemoteHost"] = finalConnectionInfo.originalHost
                        sessionDict["frpRemotePort"] = finalConnectionInfo.originalPort
                        print("🔗 [SessionConnectionManager] Using frp tunnel: \(finalConnectionInfo.originalHost):\(finalConnectionInfo.originalPort) -> \(finalConnectionInfo.host):\(finalConnectionInfo.port)")
                    } else {
                        sessionDict["host"] = finalConnectionInfo.host
                        print("🔌 [SessionConnectionManager] Using direct connection: \(finalConnectionInfo.host):\(finalConnectionInfo.port)")
                    }

                    // Clear the status callback as we're done with network setup
                    SessionNetworking.shared.statusUpdateCallback = nil

                    self.startScrcpyConnection(sessionDict: sessionDict, connectionInfo: finalConnectionInfo)
                }
                
            } catch {
                await MainActor.run {
                    // Clear the status callback on error
                    SessionNetworking.shared.statusUpdateCallback = nil
                    self.handleConnectionError(
                        title: "Connection Error",
                        message: "Failed to establish connection: \(error.localizedDescription)",
                        errorCallback: errorCallback
                    )
                }
            }
        }
    }
    
    /// 开始 Scrcpy 连接
    /// - Parameters:
    ///   - sessionDict: 会话字典
    ///   - connectionInfo: 连接信息
    private func startScrcpyConnection(sessionDict: [String: Any], connectionInfo: NetworkConnectionInfo) {
        print("🔗 [SessionConnectionManager] Starting Scrcpy client connection")
        
        // 创建或获取 ScrcpyClientWrapper 实例
        if scrcpyClientWrapper == nil {
            scrcpyClientWrapper = ScrcpyClientWrapper()
        }
        
        scrcpyClientWrapper?.startClient(sessionDict) { [weak self] statusCode, message in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                switch statusCode.rawValue {
                case ScrcpyStatusSDLWindowAppeared.rawValue:
                    print("✅ [SessionConnectionManager] Successfully connected to session")
                    
                case ScrcpyStatusConnectingFailed.rawValue:
                    print("❌ [SessionConnectionManager] Failed to connect to session")
                    // 重试逻辑已移至 performConnection，这里不再处理。
                    // 如果 Tailscale 已经成功分配 IP，但连接失败，通常是目标设备服务未运行或防火墙问题。
                    if connectionInfo.isUsingTailscale {
                        print("ℹ️ [SessionConnectionManager] Tailscale connection failed. This may be due to the target service not running or a network issue. No further retries will be attempted.")
                    }
                    
                default:
                    print("🔄 [SessionConnectionManager] Connection status: \(statusCode.description)")
                    if !message.isEmpty {
                        print("📝 [SessionConnectionManager] Status message: \(message)")
                    }
                }
            }
        }
    }
    
    /// 处理连接错误
    /// - Parameters:
    ///   - title: 错误标题
    ///   - message: 错误消息
    ///   - errorCallback: 错误回调（现在不再使用）
    private func handleConnectionError(title: String, message: String, errorCallback: ConnectionErrorCallback) {
        print("❌ [SessionConnectionManager] Connection error: \(title) - \(message)")
        
        isConnecting = false
        connectionStatus = ScrcpyStatusConnectingFailed
        
        // 清除连接中的会话信息，因为连接失败了
        connectingSession = nil
        
        // 通过状态回调传递错误信息到 ConnectionStatusView
        if let callback = currentConnectionCallback {
            callback(ScrcpyStatusConnectingFailed, message, false)
        }
        
        // 不自动清理当前会话，等待用户主动 dismiss
        
        print("📝 [SessionConnectionManager] Error message passed to ConnectionStatusView: \(message)")
    }
    
    /// 设置当前连接的会话
    /// - Parameters:
    ///   - session: 会话模型
    ///   - connectionInfo: 连接信息（包含实际的 host 和 port）
    func setCurrentSession(_ session: ScrcpySessionModel, connectionInfo: NetworkConnectionInfo?) {
        currentSession = session
        
        // 清除连接中的会话信息，因为现在已经设置为当前会话
        connectingSession = nil
        
        if let info = connectionInfo {
            actualHost = info.host
            actualPort = info.port
            isUsingTailscale = info.isUsingTailscale
            isUsingFrp = info.isUsingFrp
            tailscaleLocalPort = info.localForwardPort
        } else {
            actualHost = session.hostReal
            actualPort = session.port
            isUsingTailscale = false
            isUsingFrp = false
            tailscaleLocalPort = nil
        }
        
        connectionStatus = ScrcpyStatusConnecting
        
        print("📱 [SessionConnectionManager] Current session set: \(session.sessionName)")
        print("📍 [SessionConnectionManager] Connection: \(actualHost ?? "unknown"):\(actualPort ?? "unknown")")
        if isUsingTailscale {
            print("🔗 [SessionConnectionManager] Using Tailscale (local port: \(tailscaleLocalPort ?? 0))")
        }
    }
    
    /// 清除当前会话信息
    func clearCurrentSession(clearPendingAction: Bool = true) {
        // ★ 留一道追踪：**会话被清 = 界面要回主页**，这是「切网后莫名回主页」
        //   这类问题的总开关。全代码库只有两个调用点（Disconnected 处理器、
        //   disconnectCurrent），都该在自动重连期间被跳过 ——
        //   万一将来又冒出一条新路径，这行会让它当场现形，
        //   不用像之前那样靠翻几百行日志猜。
        if isAutoReconnecting {
            print("⚠️ [AutoReconnect] 重连期间会话被清！调用方：\(Thread.callStackSymbols.prefix(4).joined(separator: " <- "))")
        }

        // ★ 把还在跑的连接任务也停掉。
        //
        //   不停的话它会自己跑完再回来改状态，把这里刚清干净的
        //   isConnecting / connectionStatus 又弄脏 —— 用户看到的就是
        //   「取消之后导航栏两个图标一直灰着点不动，再点连接还是卡住」。
        connectionTask?.cancel()
        connectionTask = nil

        let wasConnected = currentSession != nil
        let previousHost = actualHost
        let previousPort = actualPort

        currentSession = nil
        actualHost = nil
        actualPort = nil
        isUsingTailscale = false
        isUsingFrp = false
        tailscaleLocalPort = nil
        connectionStatus = ScrcpyStatusDisconnected
        isConnecting = false
        connectionStartTime = nil

        // Stop the silent-audio keep-alive engine if it was running —
        // there is nothing left to keep alive once the session is gone.
        BackgroundKeepAliveManager.shared.sessionDisconnected()

        // 当没有已连接的session时,清除保存的上次连接session
        // 避免下次重连了上次成功过但已经主动断开过的连接
        clearLastSession()

        // 清理待执行的动作（如果需要）
        if clearPendingAction {
            pendingAction = nil
            isConnectingWithAction = false
            hasExecutedPendingAction = false
            currentActionConfirmationCallback = nil
            pendingConfirmationAction = nil
            pendingConfirmationCallback = nil
            print("🧹 [SessionConnectionManager] Pending action cleared")
        } else {
            print("💾 [SessionConnectionManager] Pending action preserved for reconnection")
        }

        // 清理 ScrcpyClientWrapper 实例
        scrcpyClientWrapper = nil

        // 停止 Live Activity
        if #available(iOS 16.1, *),
           let manager = liveActivityManager as? ScrcpyLiveActivityManager {
            manager.stopActivity()
        }

        // 保留状态回调，立即清除
        currentConnectionCallback = nil

        // 延迟清除错误回调，确保用户能看到可能的错误消息
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.currentErrorCallback = nil
        }

        if wasConnected {
            print("🧹 [SessionConnectionManager] Session cleared - was connected to \(previousHost ?? "unknown"):\(previousPort ?? "unknown")")
            print("⏰ [SessionConnectionManager] Connection time cleared")
        } else {
            print("🧹 [SessionConnectionManager] Session cleared - no previous connection")
        }
    }
    
    /// 连接成功后清理回调
    private func cleanupCallbacksAfterSuccess() {
        print("🧹 [SessionConnectionManager] Cleaning up callbacks after successful connection")
        
        // 清理状态回调，避免 ConnectionStatusView 继续接收更新
        currentConnectionCallback = nil
        
        // 清理错误回调
        currentErrorCallback = nil
        
        print("✅ [SessionConnectionManager] Callbacks cleaned up after successful connection")
    }
    
    /// 连接失败后清理回调
    private func cleanupCallbacksAfterFailure() {
        print("🧹 [SessionConnectionManager] Cleaning up callbacks after connection failure")
        
        // 清理状态回调
        currentConnectionCallback = nil
        
        // 错误回调已经在显示错误时处理，这里确保清理
        currentErrorCallback = nil
        
        print("❌ [SessionConnectionManager] Callbacks cleaned up after connection failure")
    }
    
    /// 检查是否需要重连到新会话
    /// - Parameters:
    ///   - newSession: 新的会话
    ///   - newConnectionInfo: 新会话的连接信息
    /// - Returns: 是否需要重连
    func shouldReconnect(to newSession: ScrcpySessionModel, with newConnectionInfo: NetworkConnectionInfo?) -> Bool {
        // 如果当前没有活跃连接，直接连接
        guard connectionStatus != ScrcpyStatusDisconnected else {
            print("🆕 [SessionConnectionManager] No active connection, will connect")
            return true
        }
        
        // 获取新会话的实际连接地址
        let newHost = newConnectionInfo?.host ?? newSession.hostReal
        let newPort = newConnectionInfo?.port ?? newSession.port
        
        // 检查连接地址是否相同
        if actualHost == newHost && actualPort == newPort {
            print("🔄 [SessionConnectionManager] Same connection (\(newHost):\(newPort)), no reconnection needed")
            return false
        }
        
        // 检查会话类型是否相同
        if let currentSession = currentSession {
            if currentSession.deviceType != newSession.deviceType {
                print("🔀 [SessionConnectionManager] Different device type (\(currentSession.deviceType.rawValue) → \(newSession.deviceType.rawValue)), will reconnect")
                return true
            }
        }
        
        print("🔀 [SessionConnectionManager] Different connection (\(actualHost ?? "unknown"):\(actualPort ?? "unknown") → \(newHost):\(newPort)), will reconnect")
        return true
    }
    
    /// 断开当前连接
    /// 重连专用：拆掉旧连接和转发，但**保留会话**。
    ///
    /// ★ 为什么不直接用 disconnectCurrent()：它最后会 `clearCurrentSession()`，
    ///   把 currentSession 清成 nil —— UI 就没有会话可显示，直接回主页
    ///   （用户实测：「关闭 wifi 后他马上给我退回主页」，而他想要的是
    ///   「留在连接界面原地重连」）。
    ///
    ///   重连本来就是原地重建，会话本身一点没变，不该被清掉。
    private func teardownConnectionForReconnect() {
        print("🔌 [AutoReconnect] 拆掉旧连接（保留会话，UI 不回主页）")

        if let wrapper = scrcpyClientWrapper {
            wrapper.disconnectCurrentClient()
        } else {
            NotificationCenter.default.post(
                name: Notification.Name("ScrcpyRequestDisconnectNotification"),
                object: nil
            )
        }

        // 转发要停干净 —— 旧隧道把本机端口占着不放，新的就绑不上
        if isUsingTailscale || currentSession?.useFrp == true {
            SessionNetworking.shared.stopAllForwarding()
        }

        // ★ 这里**故意不调 clearCurrentSession()** —— 会话留着，界面就还在。
    }

    func disconnectCurrent() {
        // ★★ 用户主动断开 —— 先把「网络变化」标记清掉。
        //
        //   不清的话会有这个漏洞：切网后 15 秒内点「关闭连接」，
        //   标记还在有效期内 → Disconnected 处理器以为这是网络切断 → 自动重连
        //   （用户实测：「本身自带的菜单里面有个关闭连接的那个，我关闭之后怎么也触发重新连接了」）。
        //
        //   重连的触发条件只有一个：**网络变了**。
        //   用户主动关、或者连接本来就失败，都不该触发。
        justHadNetworkChange = false
        justHadNetworkChangeAt = nil

        guard connectionStatus != ScrcpyStatusDisconnected else {
            print("🚫 [SessionConnectionManager] Already disconnected, no action needed")
            return
        }
        
        print("🔌 [SessionConnectionManager] Disconnecting current connection")
        
        // 使用 ScrcpyClientWrapper 的 disconnect 方法
        if let wrapper = scrcpyClientWrapper {
            wrapper.disconnectCurrentClient()
        } else {
            // 备用方案：发送断开通知（用于向后兼容）
            print("⚠️ [SessionConnectionManager] No ScrcpyClientWrapper available, using notification fallback")
            NotificationCenter.default.post(
                name: Notification.Name("ScrcpyRequestDisconnectNotification"),
                object: nil
            )
        }
        
        // 清理端口转发（Tailscale 和 frp 都是「本机监听 + 转发」那一套）
        if isUsingTailscale || currentSession?.useFrp == true {
            SessionNetworking.shared.stopAllForwarding()
        }

        // 主动同步 Live Activity 状态并结束（在后台计时器断开时不会收到状态通知）
        if #available(iOS 16.1, *),
           let manager = liveActivityManager as? ScrcpyLiveActivityManager,
           manager.hasActiveActivity {
            let duration = connectionDuration
            print("🎭 [SessionConnectionManager] Sync Live Activity on background disconnect, duration: \(duration)s")
            manager.updateActivity(status: ScrcpyStatusDisconnected, statusMessage: "Disconnected in background", connectionDuration: duration)
        }

        // 清理当前会话并停止相关资源（其中包含停止 Live Activity 的保障）
        clearCurrentSession(clearPendingAction: true)
    }
    
    // MARK: - Utility Methods
    
    /// 获取当前连接的描述信息
    var connectionDescription: String {
        guard let session = currentSession else {
            return "No active connection"
        }
        
        let deviceType = session.deviceType.rawValue.uppercased()
        let sessionName = session.sessionName.isEmpty ? "\(session.hostReal):\(session.port)" : session.sessionName
        let connectionInfo = "\(actualHost ?? "unknown"):\(actualPort ?? "unknown")"
        
        var description = "[\(deviceType)] \(sessionName)"
        
        if isUsingTailscale {
            description += " via Tailscale (\(connectionInfo))"
        } else if actualHost != session.hostReal || actualPort != session.port {
            description += " → \(connectionInfo)"
        }
        
        return description
    }
    
    /// 获取连接状态的描述
    var statusDescription: String {
        return connectionStatus.description
    }
    
    /// 获取当前连接的持续时间（秒）
    var connectionDuration: TimeInterval {
        guard let startTime = connectionStartTime else {
            return 0
        }
        return Date().timeIntervalSince(startTime)
    }
    
    /// 获取格式化的连接持续时间字符串
    var formattedConnectionDuration: String {
        let duration = connectionDuration
        let minutes = Int(duration / 60)
        
        if minutes < 1 {
            return "< 1m"
        } else {
            return "\(minutes)m"
        }
    }
    
    // MARK: - Debug Methods
    
    /// 测试通知系统是否正常工作
    func testNotificationSystem() {
        print("🧪 [SessionConnectionManager] Testing notification system...")
        
        // 发送一个测试通知
        NotificationCenter.default.post(
            name: Notification.Name("ScrcpyStatusUpdated"),
            object: nil,
            userInfo: ["status": 0] // ScrcpyStatusDisconnected
        )
        
        print("🧪 [SessionConnectionManager] Test notification sent")
    }
    
    // MARK: - Live Activity Integration
    
    /// 如果需要，启动 Live Activity
    private func startLiveActivityIfNeeded() {
        guard #available(iOS 16.1, *) else { return }
        
        // 检查用户是否启用了 Live Activity
        let liveActivityEnabled = UserDefaults.standard.object(forKey: "settings.live_activity.enabled") as? Bool ?? true
        guard liveActivityEnabled else {
            print("ℹ️ [SessionConnectionManager] Live Activity disabled by user")
            return
        }
        
        guard let session = currentSession,
              connectionStatus.isActive else {
            print("ℹ️ [SessionConnectionManager] Live Activity not needed")
            return
        }
        
        guard let manager = liveActivityManager as? ScrcpyLiveActivityManager else {
            print("ℹ️ [SessionConnectionManager] Live Activity manager not available")
            return
        }
        
        guard !manager.hasActiveActivity else {
            print("ℹ️ [SessionConnectionManager] Live Activity already active")
            return
        }
        
        print("🎭 [SessionConnectionManager] Starting Live Activity for background session")
        
        let sessionName = session.sessionName.isEmpty ? "\(session.hostReal):\(session.port)" : session.sessionName
        let deviceType = session.deviceType.rawValue
        let host = actualHost ?? session.hostReal
        let port = actualPort ?? session.port
        
        // 如果已经连接，使用实际的连接开始时间
        let actualStartTime = connectionStartTime ?? Date()
        
        manager.startActivity(
            sessionName: sessionName,
            deviceType: deviceType,
            hostAddress: host,
            port: port,
            initialStatus: connectionStatus,
            isUsingTailscale: isUsingTailscale,
            connectionStartTime: actualStartTime
        )
    }
    
    /// 如果需要，更新 Live Activity
    private func updateLiveActivityIfNeeded(status: ScrcpyStatus, message: String?) {
        guard #available(iOS 16.1, *) else { return }
        
        guard let manager = liveActivityManager as? ScrcpyLiveActivityManager else {
            return
        }
        
        guard manager.hasActiveActivity else {
            print("ℹ️ [SessionConnectionManager] No active Live Activity to update")
            return
        }
        
        let actualDuration = connectionDuration
        print("🔄 [SessionConnectionManager] Updating Live Activity with status: \(status.description), duration: \(actualDuration)s")
        manager.updateActivity(status: status, statusMessage: message, connectionDuration: actualDuration)
    }
    
    /// 检查 Live Activity 是否可用
    @available(iOS 16.1, *)
    var isLiveActivityAvailable: Bool {
        if let manager = liveActivityManager as? ScrcpyLiveActivityManager {
            return manager.isActivityAvailable
        }
        return false
    }
    
    /// 手动启动 Live Activity（用于测试或用户主动启动）
    @available(iOS 16.1, *)
    func startLiveActivity() {
        startLiveActivityIfNeeded()
    }
    
    /// 手动停止 Live Activity
    @available(iOS 16.1, *)
    func stopLiveActivity() {
        if let manager = liveActivityManager as? ScrcpyLiveActivityManager {
            manager.stopActivity()
        }
    }
    
    // MARK: - Action Execution Methods
    
    /// 执行待执行的动作（如果有）
    private func executePendingActionIfNeeded() {
        print("🔍 [SessionConnectionManager] Checking for pending action...")
        print("📊 [SessionConnectionManager] isConnectingWithAction: \(isConnectingWithAction)")
        print("📋 [SessionConnectionManager] pendingAction: \(pendingAction?.name ?? "nil")")
        print("✅ [SessionConnectionManager] hasExecutedPendingAction: \(hasExecutedPendingAction)")
        
        guard let action = pendingAction else {
            print("ℹ️ [SessionConnectionManager] No pending action to execute")
            return
        }
        
        guard !hasExecutedPendingAction else {
            print("⚠️ [SessionConnectionManager] Pending action already executed, skipping")
            return
        }
        
        print("🎬 [SessionConnectionManager] Executing pending action: \(action.name)")
        hasExecutedPendingAction = true
        
        switch action.executionTiming {
        case .immediate:
            print("⚡ [SessionConnectionManager] Executing action immediately")
            executeAction(action)
        case .delayed:
            print("⏰ [SessionConnectionManager] Executing action after \(action.delaySeconds) seconds delay")
            DispatchQueue.main.asyncAfter(deadline: .now() + TimeInterval(action.delaySeconds)) {
                self.executeAction(action)
            }
        case .confirmation:
            print("❓ [SessionConnectionManager] Action requires confirmation after connection")
            // 如果有确认回调，调用它；否则直接执行（兼容性）
            if let confirmationCallback = currentActionConfirmationCallback {
                confirmationCallback(action) { [weak self] in
                    print("✅ [SessionConnectionManager] User confirmed action, executing")
                    self?.executeAction(action)
                }
            } else {
                print("⚠️ [SessionConnectionManager] No confirmation callback, executing directly")
                executeAction(action)
            }
        }
        
        // 清理待执行的动作和标志
        pendingAction = nil
        isConnectingWithAction = false
        hasExecutedPendingAction = false
        currentActionConfirmationCallback = nil
        pendingConfirmationAction = nil
        pendingConfirmationCallback = nil
    }
    
    /// 执行具体的动作
    /// - Parameter action: 要执行的动作
    private func executeAction(_ action: ScrcpyAction) {
        guard let currentSession = currentSession else {
            print("❌ [SessionConnectionManager] Cannot execute action: no current session")
            return
        }
        
        print("🚀 [SessionConnectionManager] Executing action: \(action.name)")
        print("🔧 [SessionConnectionManager] Device type: \(currentSession.deviceType)")
        
        switch currentSession.deviceType {
        case .vnc:
            print("🖥️ [SessionConnectionManager] Delegating VNC actions to VNC client")
            executeVNCActionsUsingClient(action)
        case .adb:
            print("📱 [SessionConnectionManager] Delegating ADB action to ADB client")
            executeADBActionUsingClient(action)
        @unknown default:
            print("⚠️ [SessionConnectionManager] Unknown device type: \(currentSession.deviceType)")
        }
        
        print("✅ [SessionConnectionManager] Action execution delegated successfully")
    }
    
    // MARK: - VNC Action Execution via Client
    
    /// 使用 ScrcpyClientWrapper 执行 VNC 动作
    /// - Parameter action: VNC 动作
    private func executeVNCActionsUsingClient(_ action: ScrcpyAction) {
        guard !action.vncQuickActions.isEmpty else {
            print("ℹ️ [SessionConnectionManager] No VNC actions to execute")
            return
        }
        
        guard let clientWrapper = scrcpyClientWrapper else {
            print("❌ [SessionConnectionManager] Cannot execute VNC actions: no ScrcpyClientWrapper available")
            return
        }
        
        print("🖥️ [SessionConnectionManager] Executing \(action.vncQuickActions.count) VNC actions via ScrcpyClientWrapper")
        
        // 检查是否包含 Input Keys 动作且需要键配置
        let hasInputKeys = action.vncQuickActions.contains(.inputKeys)
        if hasInputKeys && !action.vncInputKeysConfig.keys.isEmpty {
            // 执行带有键配置的 VNC 动作
            executeVNCActionsWithKeyConfig(action)
        } else {
            // 执行基本的 VNC 快捷动作
            let actionNumbers = action.vncQuickActions.compactMap { vncAction -> NSNumber? in
                return NSNumber(value: vncAction.toVNCQuickActionType())
            }
            
            clientWrapper.executeVNCActions(actionNumbers) { success, error  in
                DispatchQueue.main.async {
                    if success {
                        print("✅ [SessionConnectionManager] VNC actions executed successfully")
                    } else {
                        print("❌ [SessionConnectionManager] VNC actions execution failed: \(error ?? "Unknown error")")
                    }
                }
            }
        }
    }
    
    /// 执行带有键配置的 VNC 动作
    /// - Parameter action: 包含键配置的 VNC 动作
    private func executeVNCActionsWithKeyConfig(_ action: ScrcpyAction) {
        guard let clientWrapper = scrcpyClientWrapper else {
            print("❌ [SessionConnectionManager] Cannot execute VNC key actions: no ScrcpyClientWrapper available")
            return
        }
        
        print("🔧 [SessionConnectionManager] Executing VNC actions with \(action.vncInputKeysConfig.keys.count) configured keys")
        
        // 构建键动作序列
        var keyActions: [[String: Any]] = []
        
        // 处理每个配置的键
        for vncKeyAction in action.vncInputKeysConfig.keys {
            if !vncKeyAction.modifiers.isEmpty {
                // 处理带修饰符的键
                for modifier in vncKeyAction.modifiers {
                    let modifierAction = [
                        "type": "key",
                        "keyCode": String(modifier.toVNCKeyCode()),
                        "action": "down" // 按下修饰符
                    ]
                    keyActions.append(modifierAction)
                }
                
                // 按下主键
                let mainKeyAction = [
                    "type": "key",
                    "keyCode": String(vncKeyAction.keyCode),
                    "action": "press" // 完整按键
                ]
                keyActions.append(mainKeyAction)
                
                // 释放修饰符（逆序）
                for modifier in vncKeyAction.modifiers.reversed() {
                    let modifierReleaseAction = [
                        "type": "key",
                        "keyCode": String(modifier.toVNCKeyCode()),
                        "action": "up" // 释放修饰符
                    ]
                    keyActions.append(modifierReleaseAction)
                }
            } else {
                // 处理简单键
                let keyAction = [
                    "type": "key",
                    "keyCode": String(vncKeyAction.keyCode),
                    "action": "press"
                ]
                keyActions.append(keyAction)
            }
        }
        
        // 如果还有其他 VNC 快捷动作（如 Sync Clipboard），也要执行
        let otherActions = action.vncQuickActions.filter { $0 != .inputKeys }
        if !otherActions.isEmpty {
            let actionNumbers = otherActions.compactMap { vncAction -> NSNumber? in
                return NSNumber(value: vncAction.toVNCQuickActionType())
            }
            
            // 先执行键动作，再执行其他快捷动作
            executeVNCKeyActionsDirectly(keyActions, intervalMs: action.vncInputKeysConfig.intervalMs) { success, error in
                if success {
                    print("✅ [SessionConnectionManager] VNC key actions executed successfully")
                    // 执行其他快捷动作
                    clientWrapper.executeVNCActions(actionNumbers) { success2, error2 in
                        DispatchQueue.main.async {
                            if success2 {
                                print("✅ [SessionConnectionManager] All VNC actions executed successfully")
                            } else {
                                print("❌ [SessionConnectionManager] VNC other actions failed: \(error2 ?? "Unknown error")")
                            }
                        }
                    }
                } else {
                    print("❌ [SessionConnectionManager] VNC key actions failed: \(error ?? "Unknown error")")
                }
            }
        } else {
            // 只执行键动作
            executeVNCKeyActionsDirectly(keyActions, intervalMs: action.vncInputKeysConfig.intervalMs) { success, error in
                DispatchQueue.main.async {
                    if success {
                        print("✅ [SessionConnectionManager] VNC key actions executed successfully")
                    } else {
                        print("❌ [SessionConnectionManager] VNC key actions failed: \(error ?? "Unknown error")")
                    }
                }
            }
        }
    }
    
    /// 直接执行 VNC 键动作（使用字典格式）
    /// - Parameters:
    ///   - keyActions: 键动作字典数组
    ///   - completion: 完成回调
    private func executeVNCKeyActionsDirectly(_ keyActions: [[String: Any]], intervalMs: Int, completion: @escaping (Bool, String?) -> Void) {
        guard let clientWrapper = scrcpyClientWrapper else {
            completion(false, "No ScrcpyClientWrapper available")
            return
        }
        // 实际发送键事件到 VNC 客户端（通过通知）
        // 参照 ScrcpyVNCClient.m 中的 handleVNCKeyboardEvent -> sendKeyEvent 实现
        let notificationName = Notification.Name("ScrcpyVNCKeyboardEventNotification")
        let typeKey = "type" // kKeyType
        let keyCodeKey = "keyCode" // kKeyKeyCode
        let keyDown = "keyDown" // kKeyboardEventTypeKeyDown
        let keyUp = "keyUp"     // kKeyboardEventTypeKeyUp

        // 打印调试信息
        print("🔧 [SessionConnectionManager] Executing \(keyActions.count) VNC key actions (interval: \(intervalMs)ms)")

        // 事件调度：按顺序依次发送，支持 press/down/up
        let intervalSec = max(0, Double(intervalMs)) / 1000.0
        let pressHoldSec = min(0.06, max(0.02, intervalSec / 2.0)) // 按下到抬起的最小保持时间

        var cumulativeDelay: TimeInterval = 0

        for (index, keyAction) in keyActions.enumerated() {
            guard let codeStr = keyAction["keyCode"] as? String,
                  let code = Int(codeStr) else {
                print("⚠️ [SessionConnectionManager] Invalid key action (missing/invalid keyCode): \(keyAction)")
                continue
            }

            let action = (keyAction["action"] as? String ?? "press").lowercased()

            // 发送 keyDown
            if action == "down" || action == "press" {
                let delay = cumulativeDelay
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) {
                    NotificationCenter.default.post(name: notificationName, object: nil, userInfo: [typeKey: keyDown, keyCodeKey: NSNumber(value: code)])
                    print("⌨️ [SessionConnectionManager] -> keyDown \(code) (step \(index + 1))")
                }
            }

            // 发送 keyUp
            if action == "up" || action == "press" {
                let upDelay = cumulativeDelay + (action == "press" ? pressHoldSec : 0)
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + upDelay) {
                    NotificationCenter.default.post(name: notificationName, object: nil, userInfo: [typeKey: keyUp, keyCodeKey: NSNumber(value: code)])
                    print("⌨️ [SessionConnectionManager] -> keyUp \(code) (step \(index + 1))")
                }
            }

            // 累计间隔用于下一个按键
            cumulativeDelay += max(intervalSec, pressHoldSec)
        }

        // 在最后一个事件完成后回调完成
        let completionDelay = cumulativeDelay + 0.05
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + completionDelay) {
            completion(true, nil)
        }
    }
    
    // MARK: - ADB Action Execution via Client
    
    /// 使用 ScrcpyClientWrapper 执行 ADB 动作
    /// - Parameter action: ADB 动作
    private func executeADBActionUsingClient(_ action: ScrcpyAction) {
        guard let deviceSerial = getADBDeviceSerial() else {
            print("❌ [SessionConnectionManager] Cannot execute ADB action: no ADB device serial available")
            return
        }
        
        guard let clientWrapper = scrcpyClientWrapper else {
            print("❌ [SessionConnectionManager] Cannot execute ADB action: no ScrcpyClientWrapper available")
            return
        }
        
        print("📱 [SessionConnectionManager] Executing ADB action type: \(action.adbActionType.rawValue)")
        print("🎯 [SessionConnectionManager] Target ADB device serial: \(deviceSerial)")
        
        switch action.adbActionType {
        case .homeKey:
            print("🏠 [SessionConnectionManager] Executing Home key via ScrcpyClientWrapper")
            clientWrapper.executeADBHomeKey(onDevice: deviceSerial) { output, returnCode in
                DispatchQueue.main.async {
                    if returnCode == 0 {
                        print("✅ [SessionConnectionManager] Home key executed successfully on device: \(deviceSerial)")
                    } else {
                        print("❌ [SessionConnectionManager] Home key execution failed on device: \(deviceSerial), output: \(output ?? "N/A")")
                    }
                }
            }
            
        case .switchKey:
            print("🔀 [SessionConnectionManager] Executing Switch key via ScrcpyClientWrapper")
            clientWrapper.executeADBSwitchKey(onDevice: deviceSerial) { output, returnCode in
                DispatchQueue.main.async {
                    if returnCode == 0 {
                        print("✅ [SessionConnectionManager] Switch key executed successfully on device: \(deviceSerial)")
                    } else {
                        print("❌ [SessionConnectionManager] Switch key execution failed on device: \(deviceSerial), output: \(output ?? "N/A")")
                    }
                }
            }
            
        case .inputKeys:
            print("⌨️ [SessionConnectionManager] Executing input keys via ScrcpyClientWrapper")
            let keyCodes = action.adbInputKeysConfig.keys.map { NSNumber(value: $0.keyCode) }
            clientWrapper.executeADBKeySequence(keyCodes, onDevice: deviceSerial, interval: action.adbInputKeysConfig.intervalMs) { successCount, totalCount in
                DispatchQueue.main.async {
                    print("✅ [SessionConnectionManager] Key sequence execution completed: \(successCount)/\(totalCount) successful on device: \(deviceSerial)")
                }
            }
            
        case .shellCommands:
            print("💻 [SessionConnectionManager] Executing shell commands via ScrcpyClientWrapper")
            let commandLines = action.adbShellConfig.commands.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            clientWrapper.executeADBShellCommands(commandLines, onDevice: deviceSerial, interval: action.adbShellConfig.intervalMs) { successCount, totalCount in
                DispatchQueue.main.async {
                    print("✅ [SessionConnectionManager] Shell commands execution completed: \(successCount)/\(totalCount) successful on device: \(deviceSerial)")
                }
            }
        }
    }
    

    
    /// 获取当前设备地址（host:port格式）
    /// - Returns: 设备地址字符串，如果不可用则返回nil
    private func getDeviceAddress() -> String? {
        // 优先使用实际连接的地址（可能经过Tailscale代理）
        if let actualHost = actualHost, let actualPort = actualPort {
            return "\(actualHost):\(actualPort)"
        }
        
        // 备用方案：使用session中的原始地址
        if let session = currentSession {
            return "\(session.hostReal):\(session.port)"
        }
        
        return nil
    }
    
    /// 获取当前 ADB 设备的序列号（用于 ADB 命令执行）
    /// - Returns: ADB 设备序列号字符串，如果不可用则返回nil
    private func getADBDeviceSerial() -> String? {
        guard let session = currentSession, session.deviceType == .adb else {
            print("❌ [SessionConnectionManager] Cannot get ADB serial: no ADB session")
            return nil
        }
        
        // 如果通过 Tailscale 连接，使用 Tailscale 的本地转发地址作为设备序列号
        // 否则，使用原始的 host:port 作为设备序列号
        let adbSerial: String
        if isUsingTailscale, let host = actualHost, let port = actualPort {
            adbSerial = "\(host):\(port)"
            print("🔍 [SessionConnectionManager] ADB device serial (via Tailscale): \(adbSerial)")
        } else {
            adbSerial = "\(session.hostReal):\(session.port)"
            print("🔍 [SessionConnectionManager] ADB device serial: \(adbSerial)")
            if let actualHost = actualHost, let actualPort = actualPort,
               (actualHost != session.hostReal || actualPort != session.port) {
                print("🔗 [SessionConnectionManager] Connection via proxy: \(actualHost):\(actualPort)")
            }
        }
        
        return adbSerial
    }
    
    /// 设置等待确认的动作
    /// - Parameters:
    ///   - action: 等待确认的动作
    ///   - callback: 确认后的回调
    func setConfirmationAction(_ action: ScrcpyAction, callback: @escaping () -> Void) {
        pendingConfirmationAction = action
        pendingConfirmationCallback = callback
        print("💾 [SessionConnectionManager] Confirmation action set: \(action.name)")
    }
    
    /// 执行确认的动作
    func executeConfirmedAction() {
        guard let callback = pendingConfirmationCallback else {
            print("⚠️ [SessionConnectionManager] No pending confirmation callback")
            return
        }
        
        print("✅ [SessionConnectionManager] Executing confirmed action")
        callback()
        
        // 清理确认状态
        pendingConfirmationAction = nil
        pendingConfirmationCallback = nil
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Objective-C Bridge Methods
    
    /// 获取当前连接的设备类型，供Objective-C代码调用
    /// - Returns: 设备类型字符串，"adb"或"vnc"，如果没有连接则返回nil
    @objc public func getCurrentDeviceType() -> String? {
        return currentSession?.deviceType.rawValue
    }
    
    /// 检查是否有当前活跃的连接，供Objective-C代码调用
    /// - Returns: 是否有活跃连接
    @objc public func hasActiveConnection() -> Bool {
        return currentSession != nil && connectionStatus.isActive
    }
    
    // MARK: - Error Detection Methods
    
    /// 检查scrcpy进程的最后输出中是否包含ERROR关键字，如果有则显示Alert
    private func checkForErrorsAndShowAlert() {
        // 调用C接口获取最后的输出
        guard let lastOutputCStr = scrcpy_process_get_last_output() else {
            print("ℹ️ [SessionConnectionManager] No last output available from scrcpy process")
            return
        }
        
        let lastOutput = String(cString: lastOutputCStr)
        print("📝 [SessionConnectionManager] Last scrcpy output: \(lastOutput)")
        
        // 检查输出中是否包含错误关键字（不区分大小写）
        let errorKeywords = ["ERROR:", "FATAL:", "CRITICAL:", "FAILED:"]
        let upperOutput = lastOutput.uppercased()
        
        if let foundKeyword = errorKeywords.first(where: { upperOutput.contains($0) }) {
            print("🚨 [SessionConnectionManager] Found \(foundKeyword) in scrcpy output, showing alert to user")
            
            // 提取错误相关的行
            let errorLines = extractErrorLines(from: lastOutput, keyword: foundKeyword)
            
            // 在主线程显示Alert
            DispatchQueue.main.async {
                self.showErrorAlert(with: errorLines)
            }
        } else {
            print("✅ [SessionConnectionManager] No error keywords found in scrcpy output")
        }
    }
    
    /// 从输出中提取包含错误关键字的行
    /// - Parameters:
    ///   - output: 完整的输出文本
    ///   - keyword: 找到的错误关键字
    /// - Returns: 包含错误的行组成的字符串
    private func extractErrorLines(from output: String, keyword: String) -> String {
        let lines = output.components(separatedBy: .newlines)
        let errorKeywords = ["ERROR:", "FATAL:", "CRITICAL:", "FAILED:"]
        
        // 查找包含任何错误关键字的行
        let errorLines = lines.filter { line in
            let upperLine = line.uppercased()
            return errorKeywords.contains { keyword in
                upperLine.contains(keyword)
            }
        }
        
        if errorLines.isEmpty {
            // 如果没有找到具体的错误行，返回整个输出的最后几行
            let lastLines = Array(lines.suffix(5)).joined(separator: "\n")
            return lastLines.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            // 返回错误行，但限制最多5行以免Alert过长
            let limitedErrorLines = Array(errorLines.prefix(5))
            return limitedErrorLines.joined(separator: "\n")
        }
    }
    
    /// 显示错误Alert给用户
    /// - Parameter errorMessage: 错误消息
    private func showErrorAlert(with errorMessage: String) {
        guard let frontmostWindow = getFrontmostWindow() else {
            print("❌ [SessionConnectionManager] No frontmost window found, cannot show error alert")
            return
        }
        
        print("🚨 [SessionConnectionManager] Showing error alert to user")
        
        // 限制错误消息长度，避免Alert过大
        let maxLength = 500
        let truncatedMessage = errorMessage.count > maxLength ? 
            String(errorMessage.prefix(maxLength)) + "..." : errorMessage
        
        let alert = UIAlertController(
            title: NSLocalizedString("Scrcpy Connection Error", comment: "Alert title when scrcpy connection fails"),
            message: String(
                format: NSLocalizedString("The connection was terminated due to an error:\n\n%@", comment: "Alert message for scrcpy connection error with details"),
                truncatedMessage
            ),
            preferredStyle: .alert
        )
        
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "OK button"), style: .default) { _ in
            print("✅ [SessionConnectionManager] User acknowledged error alert")
        })
        
        // 如果消息被截断，添加"查看详情"按钮
        if errorMessage.count > maxLength {
            alert.addAction(UIAlertAction(title: NSLocalizedString("View Details", comment: "View details button"), style: .default) { _ in
                print("📋 [SessionConnectionManager] User requested full error details")
                self.showDetailedErrorAlert(with: errorMessage)
            })
        }
        
        // 从最前显示的窗口的根视图控制器展示Alert
        if let rootViewController = frontmostWindow.rootViewController {
            var topViewController = rootViewController
            
            // 找到最顶层的视图控制器
            while let presentedViewController = topViewController.presentedViewController {
                topViewController = presentedViewController
            }
            
            topViewController.present(alert, animated: true) {
                print("🎯 [SessionConnectionManager] Error alert presented successfully")
            }
        } else {
            print("❌ [SessionConnectionManager] No root view controller found on frontmost window")
        }
    }
    
    /// 获取最前显示的窗口
    /// - Returns: 最前显示的UIWindow实例
    private func getFrontmostWindow() -> UIWindow? {
        if #available(iOS 13.0, *) {
            // iOS 13+ 从活跃的 UIWindowScene 中获取关键窗口
            for scene in UIApplication.shared.connectedScenes {
                guard let windowScene = scene as? UIWindowScene,
                      windowScene.activationState == .foregroundActive else {
                    continue
                }
                
                // 获取该场景中的关键窗口
                for window in windowScene.windows {
                    if window.isKeyWindow {
                        return window
                    }
                }
                
                // 如果没有关键窗口，返回第一个可见窗口
                return windowScene.windows.first { $0.isHidden == false }
            }
        } else {
            // iOS 12 及以下使用传统方式
            if let keyWindow = UIApplication.shared.keyWindow {
                return keyWindow
            }
            return UIApplication.shared.windows.first { $0.isHidden == false }
        }
        
        return nil
    }
    
    /// 显示详细错误信息Alert
    /// - Parameter errorMessage: 完整的错误消息
    private func showDetailedErrorAlert(with errorMessage: String) {
        guard let frontmostWindow = getFrontmostWindow() else {
            print("❌ [SessionConnectionManager] No frontmost window found for detailed error alert")
            return
        }
        
        print("📋 [SessionConnectionManager] Showing detailed error alert")
        
        let alert = UIAlertController(
            title: NSLocalizedString("Detailed Error Information", comment: "Title for detailed error info alert"),
            message: errorMessage,
            preferredStyle: .alert
        )
        
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "OK button"), style: .default) { _ in
            print("✅ [SessionConnectionManager] User closed detailed error alert")
        })
        
        // 从最前显示的窗口的根视图控制器展示Alert
        if let rootViewController = frontmostWindow.rootViewController {
            var topViewController = rootViewController
            
            // 找到最顶层的视图控制器
            while let presentedViewController = topViewController.presentedViewController {
                topViewController = presentedViewController
            }
            
            topViewController.present(alert, animated: true) {
                print("📋 [SessionConnectionManager] Detailed error alert presented successfully")
            }
        }
    }

    // MARK: - Auto Reconnect Methods

    /// 保存当前会话(如果启用了自动重连)
    private func saveCurrentSessionIfAutoReconnectEnabled() {
        let autoReconnectEnabled = UserDefaults.standard.bool(forKey: "settings.auto_reconnect.enabled")
        guard autoReconnectEnabled else {
            print("ℹ️ [SessionConnectionManager] Auto reconnect disabled, skip saving session on connect")
            return
        }

        guard let session = currentSession else {
            print("⚠️ [SessionConnectionManager] No current session to save on connect")
            return
        }

        print("💾 [SessionConnectionManager] Connection successful, saving session for auto-reconnect...")
        print("   - Session name: \(session.sessionName)")
        print("   - Session host: \(session.hostReal)")
        print("   - Session port: \(session.port)")
        print("   - Device type: \(session.deviceType.rawValue)")
        saveLastSession(session)
    }

    /// 保存上次连接的会话到 UserDefaults
    /// - Parameter session: 要保存的会话
    private func saveLastSession(_ session: ScrcpySessionModel) {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(session)
            UserDefaults.standard.set(data, forKey: lastSessionKey)
            print("✅ [SessionConnectionManager] Last session saved successfully to UserDefaults")
        } catch {
            print("❌ [SessionConnectionManager] Failed to save last session: \(error)")
        }
    }

    /// 从 UserDefaults 恢复上次连接的会话
    /// - Returns: 上次连接的会话,如果不存在或解析失败则返回 nil
    private func loadLastSession() -> ScrcpySessionModel? {
        guard let data = UserDefaults.standard.data(forKey: lastSessionKey) else {
            print("ℹ️ [SessionConnectionManager] No saved last session found")
            return nil
        }

        do {
            let decoder = JSONDecoder()
            let session = try decoder.decode(ScrcpySessionModel.self, from: data)
            print("📂 [SessionConnectionManager] Last session loaded successfully: \(session.sessionName)")
            return session
        } catch {
            print("❌ [SessionConnectionManager] Failed to load last session: \(error)")
            return nil
        }
    }

    /// 清除保存的上次连接会话
    private func clearLastSession() {
        UserDefaults.standard.removeObject(forKey: lastSessionKey)
        print("🧹 [SessionConnectionManager] Last session cleared")
    }

    /// 尝试自动重连(如果需要)
    private func attemptAutoReconnectIfNeeded() {
        print("🔍 [SessionConnectionManager] --- Auto Reconnect Check Start ---")

        // 检查是否有待处理的 URL scheme,如果有则优先处理 URL scheme
        if AppSchemeManagerV2.shared.pendingScheme != nil {
            print("⏭️ [SessionConnectionManager] URL scheme is pending, skipping auto reconnect")
            print("🔍 [SessionConnectionManager] --- Auto Reconnect Check End ---")
            return
        }

        // 检查是否启用了自动重连
        let autoReconnectEnabled = UserDefaults.standard.bool(forKey: "settings.auto_reconnect.enabled")
        print("⚙️ [SessionConnectionManager] Auto reconnect setting: \(autoReconnectEnabled)")

        guard autoReconnectEnabled else {
            print("⏭️ [SessionConnectionManager] Auto reconnect is disabled, skipping")
            print("🔍 [SessionConnectionManager] --- Auto Reconnect Check End ---")
            return
        }

        // 如果当前已经有活跃连接,不需要重连
        print("📊 [SessionConnectionManager] Checking current connection state...")
        print("   - Is active: \(connectionStatus.isActive)")
        print("   - Is connecting: \(isConnecting)")

        guard !connectionStatus.isActive else {
            print("✅ [SessionConnectionManager] Already connected, no need to reconnect")
            print("🧹 [SessionConnectionManager] Clearing saved session to avoid duplicate")
            clearLastSession()
            print("🔍 [SessionConnectionManager] --- Auto Reconnect Check End ---")
            return
        }

        // 如果正在连接中,不尝试重连
        guard !isConnecting else {
            print("🔄 [SessionConnectionManager] Already connecting, skip auto reconnect")
            print("🔍 [SessionConnectionManager] --- Auto Reconnect Check End ---")
            return
        }

        // 尝试加载上次保存的会话
        print("📂 [SessionConnectionManager] Loading saved session...")
        guard let lastSession = loadLastSession() else {
            print("ℹ️ [SessionConnectionManager] No saved session found, nothing to reconnect")
            print("🔍 [SessionConnectionManager] --- Auto Reconnect Check End ---")
            return
        }

        print("✅ [SessionConnectionManager] Found saved session to reconnect:")
        print("   - Session name: \(lastSession.sessionName)")
        print("   - Session host: \(lastSession.hostReal)")
        print("   - Session port: \(lastSession.port)")
        print("   - Device type: \(lastSession.deviceType.rawValue)")
        print("⏰ [SessionConnectionManager] Will attempt reconnect after 0.5 second delay...")

        // 延迟一小段时间再重连,避免在应用启动过程中立即连接
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }

            print("⏰ [SessionConnectionManager] Delay completed, rechecking connection state...")

            // 再次检查连接状态,确保在延迟期间没有建立连接
            guard !self.connectionStatus.isActive && !self.isConnecting else {
                print("✅ [SessionConnectionManager] Connection already established during delay")
                print("🧹 [SessionConnectionManager] Clearing saved session")
                self.clearLastSession()
                print("🔍 [SessionConnectionManager] --- Auto Reconnect Attempt Cancelled ---")
                return
            }

            print("🚀 [SessionConnectionManager] Starting auto reconnect...")
            print("🔍 [SessionConnectionManager] --- Auto Reconnect Check End ---")

            // 执行自动重连
            self.connectToSession(lastSession,
                statusCallback: { status, message, isConnecting in
                    print("🔄 [SessionConnectionManager] Auto reconnect status update:")
                    print("   - Status: \(status.description)")
                    print("   - Is connecting: \(isConnecting)")
                    if let msg = message {
                        print("   - Message: \(msg)")
                    }
                },
                errorCallback: { title, message in
                    print("❌ [SessionConnectionManager] Auto reconnect failed:")
                    print("   - Title: \(title)")
                    print("   - Message: \(message)")
                    print("🧹 [SessionConnectionManager] Clearing saved session after failure")
                    self.clearLastSession()
                }
            )
        }
    }
}

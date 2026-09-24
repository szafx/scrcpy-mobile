//
//  ContentView.swift
//  Scrcpy Remote
//
//  Created by Ethan on 12/5/24.
//

import SwiftUI

/// 「新建会话」和「编辑会话」合成**一个** sheet。
///
/// ★ 为什么必须合并 —— 2026-09-24 实测踩到的坑：
///   在同一个视图上挂两个 `.sheet` 时，SwiftUI **只认第一个**，第二个被静默排队，
///   日志里只留一句
///       `Currently, only presenting a single sheet is supported.`
///       `The next sheet will be presented when the currently presented sheet gets dismissed.`
///   现象是「长按设备 → 点 Edit 没有任何反应」—— 回调其实跑了（`Editing session:` 有打印），
///   是 sheet 压根没被呈现。用 `isPresented` + `item` 各挂一个同样中招。
enum SessionSheet: Identifiable {
    case create
    case edit(ScrcpySession)

    var id: String {
        switch self {
        case .create:            return "create"
        case .edit(let session): return "edit-\(session.id.uuidString)"
        }
    }
}

struct MainContentView: View {
    @StateObject private var connectionManager = SessionConnectionManager.shared

    @State private var selectedTab = 0
    @State private var sessionSheet: SessionSheet? = nil
    @State private var savedSessions: [ScrcpySession] = []
    @State private var currentStatusMessage: String?
    @State private var userDismissedConnection: Bool = false
    @State private var showMigrationAlert: Bool = false
    @State private var legacyDeviceInfo: (host: String, port: String)?
    @EnvironmentObject var appSettings: AppSettings
    
    init(sessions: [ScrcpySession] = []) {
        self._savedSessions = State(initialValue: sessions)
        
        // Configure navigation bar and tab bar appearance for iOS 14+
        if #available(iOS 14.0, *) {
            let appearance = UINavigationBarAppearance()
            appearance.configureWithDefaultBackground()
            appearance.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterial)
            appearance.shadowColor = UIColor.separator  // Add subtle shadow/border below navigation bar
            UINavigationBar.appearance().standardAppearance = appearance
            UINavigationBar.appearance().compactAppearance = appearance
            UINavigationBar.appearance().scrollEdgeAppearance = appearance
            
            let tabBarAppearance = UITabBarAppearance()
            tabBarAppearance.configureWithDefaultBackground()
            tabBarAppearance.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterial)
            UITabBar.appearance().standardAppearance = tabBarAppearance
            if #available(iOS 15.0, *) {
                UITabBar.appearance().scrollEdgeAppearance = tabBarAppearance
            }
        }
    }
    
    func reloadSessions() {
        savedSessions = SessionManager.shared.loadSessions().map {
            ScrcpySession(sessionModel: $0)
        }
        print("Reloaded sessions:", savedSessions.count)
    }
    
    /// 连接到指定会话
    private func connectToSession(_ session: ScrcpySession) {
        print("Connecting to session:", session.title)
        
        // 重置用户关闭标志，允许显示新的连接状态
        userDismissedConnection = false
        
        // 使用 SessionConnectionManager 进行连接
        SessionConnectionManager.shared.connectToSession(
            session.sessionModel,
            statusCallback: { status, message, isConnecting in
                // 状态更新由 @ObservedObject 自动处理
                DispatchQueue.main.async {
                    print("📝 [MainContentView] Status callback received - Status: \(status.description), Message: \(message ?? "nil"), IsConnecting: \(isConnecting)")
                    self.currentStatusMessage = message
                    if let msg = message {
                        print("📝 [MainContentView] Setting currentStatusMessage to: \(msg)")
                    } else {
                        print("📝 [MainContentView] Setting currentStatusMessage to nil")
                    }
                }
                
                switch status {
                case ScrcpyStatusSDLWindowAppeared:
                    print("✅ Connected to session:", session.title)
                    
                case ScrcpyStatusConnectingFailed:
                    print("❌ Failed to connect to session:", session.title)
                    
                default:
                    print("🔄 Connection status update:", status.description)
                    if let msg = message {
                        print("📝 Status message:", msg)
                    }
                }
            },
            errorCallback: { title, message in
                // 错误信息现在通过 ConnectionStatusView 展示，不再显示 alert
                print("❌ [MainContentView] Connection error: \(title) - \(message)")
                // 错误信息会通过 statusCallback 传递到 ConnectionStatusView
            }
        )
    }

    // MARK: - Computed Properties
    
    // MARK: - Migration Methods
    
    private func checkForMigration() {
        DispatchQueue.main.async {
            if SessionManager.shared.shouldShowMigrationPrompt() {
                self.legacyDeviceInfo = SessionManager.shared.getLegacyDeviceInfo()
                self.showMigrationAlert = true
            }
        }
    }
    
    private func performMigration() {
        SessionManager.shared.performUserRequestedMigration()
        reloadSessions()
        showMigrationAlert = false
    }
    
    private func declineMigration() {
        SessionManager.shared.declineMigration()
        showMigrationAlert = false
    }
    
    // MARK: - Computed Properties
    
    /// 判断是否应该显示连接状态视图
    private var shouldShowConnectionStatusView: Bool {
        // 如果用户主动关闭了连接状态视图，立即隐藏
        guard !userDismissedConnection else {
            return false
        }

        // ★ 自动重连期间**必须**显示连接界面。
        //
        //   断连那一瞬间 connectionStatus 是 Disconnected，而下面那条
        //   `connectionStatus != Disconnected` 会把它排除掉 —— 结果界面不显示，
        //   卡在投屏页面上（用户实测：「切换就卡在投屏页面」）。
        //
        //   用户要的就是「回到正在连接的那个界面」：它有进度提示，也有 Dismiss
        //   可以随时取消这次重连。
        if connectionManager.isAutoReconnecting {
            return true
        }

        // 只有在以下情况下才显示 ConnectionStatusView：
        // 1. 正在连接中
        // 2. 连接失败（等待用户主动点击 dismiss 按钮）
        // 3. 有当前会话且状态处于连接过程中（不包括连接失败）
        return connectionManager.isConnecting ||
               (connectionManager.connectionStatus == ScrcpyStatusConnectingFailed && currentStatusMessage != nil) ||
               (connectionManager.currentSession != nil &&
                connectionManager.connectionStatus != ScrcpyStatusDisconnected &&
                connectionManager.connectionStatus != ScrcpyStatusConnectingFailed &&
                connectionManager.connectionStatus.rawValue < ScrcpyStatusSDLWindowAppeared.rawValue)
    }

    var body: some View {
        RootShellView(
            selectedTab: $selectedTab,
            savedSessions: $savedSessions,
            onConnectSession: { session in
                connectToSession(session)
            },
            onDeleteSession: { id in
                print("Deleting session:", id)
                SessionManager.shared.deleteSession(id: id)
                reloadSessions()
            },
            onEditSession: { session in
                print("Editing session:", session.title)
                sessionSheet = .edit(session)
            },
            onDuplicateSession: { session in
                print("Duplicating session:", session.title)
                SessionManager.shared.saveSession(session.sessionModel)
                reloadSessions()
            },
            onCreateSession: {
                sessionSheet = .create
            }
        )
        // ★ 新建 / 编辑**共用这一个** sheet。见 `SessionSheet` 上面那段说明 ——
        //   挂两个会静默失效（点 Edit 没反应）。
        .sheet(item: $sessionSheet, onDismiss: {
            reloadSessions()
        }) { sheet in
            switch sheet {
            case .create:
                SessionCreateView()
                    .environmentObject(appSettings)
            case .edit(let session):
                SessionCreateView(sessionModel: session.sessionModel)
                    .environmentObject(appSettings)
            }
        }
        .overlay {
            if shouldShowConnectionStatusView {
                ConnectionStatusView(
                    session: ScrcpySession(sessionModel: connectionManager.currentSession ?? ScrcpySessionModel()),
                    connectionStatus: connectionManager.connectionStatus,
                    statusMessage: currentStatusMessage,
                    onCancel: {
                        print("🚫 [MainContentView] User dismissed connection")

                        // 立即设置用户关闭标志，强制隐藏连接状态视图
                        userDismissedConnection = true
                        currentStatusMessage = nil

                        // 断开连接并清理会话状态
                        SessionConnectionManager.shared.disconnectCurrent()

                        // 对于连接失败的情况，需要手动清理会话状态
                        if connectionManager.connectionStatus == ScrcpyStatusConnectingFailed {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                SessionConnectionManager.shared.clearCurrentSession()
                            }
                        }
                    }
                )
                .transition(.opacity.combined(with: .scale))
                .animation(.easeInOut(duration: 0.3), value: shouldShowConnectionStatusView)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .startSchemeConnection)) { notification in
            guard let session = notification.userInfo?["session"] as? ScrcpySessionModel else {
                print("❌ [MainContentView] No session found in scheme connection notification")
                return
            }

            print("🔗 [MainContentView] Received scheme connection request for: \(session.host):\(session.port)")

            let scrcpySession = ScrcpySession(sessionModel: session)
            connectToSession(scrcpySession)

            selectedTab = 0
        }
        .onAppear {
            if savedSessions.isEmpty {
                reloadSessions()
            }
            checkForMigration()
        }
        // Session store mutated outside this view (e.g. the DEBUG
        // harness RPC writing through SessionManager) — re-read it.
        .onReceive(NotificationCenter.default.publisher(
            for: Notification.Name("ScrcpySessionStoreChanged"))) { _ in
            reloadSessions()
        }
        .onChange(of: connectionManager.isConnecting) { isConnecting in
            if !isConnecting && connectionManager.connectionStatus != ScrcpyStatusConnectingFailed {
                print("🧹 [MainContentView] Auto-clearing currentStatusMessage (not in failure state)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    currentStatusMessage = nil
                    print("🧹 [MainContentView] currentStatusMessage cleared")
                }
            } else if !isConnecting && connectionManager.connectionStatus == ScrcpyStatusConnectingFailed {
                print("⚠️ [MainContentView] Not auto-clearing currentStatusMessage (in failure state)")
            }
        }
        .onChange(of: connectionManager.connectionStatus) { newStatus in
            print("🔄 [MainContentView] Connection status changed to: \(newStatus.description)")

            switch newStatus {
            case ScrcpyStatusSDLWindowAppeared:
                print("✅ [MainContentView] SDL Window appeared")
                userDismissedConnection = false // 重置用户关闭标志
                LatencyBadgeWindow.shared.show()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    currentStatusMessage = nil
                }

            case ScrcpyStatusConnected:
                print("✅ [MainContentView] Connection successful")
                // 连接成功就把「走哪条路 + 延迟」的气泡浮上去。
                // ★ 别只等 SDLWindowAppeared(7) —— 那个状态**只有 VNC 那条路会发**
                //   （见 ScrcpyVNCRuntime.m），scrcpy/ADB 模式压根不发，
                //   挂在那儿的话气泡永远不出现。
                LatencyBadgeWindow.shared.show()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    currentStatusMessage = nil
                }

            case ScrcpyStatusConnectingFailed:
                print("❌ [MainContentView] Connection failed, waiting for user to dismiss")
                LatencyBadgeWindow.shared.hide()

            case ScrcpyStatusDisconnected:
                print("🔌 [MainContentView] Connection disconnected, cleaning up")
                userDismissedConnection = false // 重置用户关闭标志
                currentStatusMessage = nil
                // 回到主页 = 这次连接结束：收掉浮层并**禁止它再冒出来**。
                // 网络后面再怎么变，也不该有一条「正在重连」浮在主页上
                // （用户要求：回主页就不能自动重连了，只能手动去连）。
                LatencyBadgeWindow.shared.suppressAndHide()

            default:
                break
            }
        }
        // Migration prompt
        .alert("Legacy Data Found", isPresented: $showMigrationAlert) {
            Button("Migrate") {
                performMigration()
            }
            Button("Skip", role: .cancel) {
                declineMigration()
            }
        } message: {
            if let deviceInfo = legacyDeviceInfo {
                Text("We found device settings from the previous versions:\n\n📱 Device: \(deviceInfo.host):\(deviceInfo.port)\n\nWould you like to migrate this device to the new app? A new ADB device will be created with your previous settings.")
            } else {
                Text("We found settings from the previous versions. Would you like to migrate them to the new version?")
            }
        }
    }
}

#Preview {
    MainContentView(sessions: [
        ScrcpySession(sessionModel: ScrcpySessionModel(host: "test.abc.com", port: "5555", sessionName: "Test Server")),
        ScrcpySession(sessionModel: ScrcpySessionModel(host: "vnc://myvnc.com", port: "5901", sessionName: "My VNC")),
        ScrcpySession(sessionModel: ScrcpySessionModel(host: "adb://test.example.com", port: "1555")),
        ScrcpySession(sessionModel: ScrcpySessionModel(host: "10.1.1.1", port: "8080", sessionName: "Local Device")),
        ScrcpySession(sessionModel: ScrcpySessionModel(host: "test2.examle.com", port: "5555"))
    ])
}

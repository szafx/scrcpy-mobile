//
//  RootShellView.swift
//  Scrcpy Remote
//
//  新的应用外壳：底部浮动胶囊 TabBar + Devices / Console / Settings 三页。
//
//  这个文件只负责「装订」—— 所有业务状态机（SessionConnectionManager 那套连接 /
//  重连 / 延迟气泡）仍然由 MainContentView 持有并原样传进来，这里一行都不碰。
//

import SwiftUI

/// iOS 16 用 `NavigationStack`，15 用 `NavigationView`。
/// 工程最低版本是 15.0（没改，改它要动 pbxproj），所以两种都要能编。
struct NavContainer<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(iOS 16.0, *) {
            NavigationStack { content() }
        } else {
            NavigationView { content() }
                .navigationViewStyle(StackNavigationViewStyle())
        }
    }
}

struct RootShellView: View {
    @Binding var selectedTab: Int
    @Binding var savedSessions: [ScrcpySession]

    var onConnectSession: (ScrcpySession) -> Void = { _ in }
    var onDeleteSession: (UUID) -> Void = { _ in }
    var onEditSession: (ScrcpySession) -> Void = { _ in }
    var onDuplicateSession: (ScrcpySession) -> Void = { _ in }
    var onCreateSession: () -> Void = {}

    private let tabs: [ShellTab] = [
        ShellTab(id: 0, icon: "dot.radiowaves.left.and.right", title: "Devices"),
        ShellTab(id: 1, icon: "terminal.fill", title: "Console"),
        ShellTab(id: 2, icon: "gearshape.fill", title: "Settings"),
    ]

    var body: some View {
        Group {
            switch selectedTab {
            case 0:
                NavContainer {
                    DevicesView(
                        savedSessions: $savedSessions,
                        onConnectSession: onConnectSession,
                        onDeleteSession: onDeleteSession,
                        onEditSession: onEditSession,
                        onDuplicateSession: onDuplicateSession,
                        onCreateSession: onCreateSession,
                        onOpenSettings: { selectedTab = 2 }
                    )
                }

            case 1:
                NavContainer {
                    ConsoleView(
                        savedSessions: $savedSessions,
                        onConnectSession: onConnectSession
                    )
                }

            default:
                // SettingsView 自己带 NavigationView（SettingsView.swift:293），
                // 不要再套一层。
                SettingsView()

            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 浮动胶囊浮在内容之上，同时把内容的安全区往上顶，
        // 免得列表最后一行被它盖住。
        // 注意：VRLink 在工具子页里也照样显示这条 —— 所以这里不区分层级。
        .safeAreaInset(edge: .bottom, spacing: 0) {
            FloatingTabBar(selected: $selectedTab, tabs: tabs)
                .padding(.top, 8)
                .padding(.bottom, 4)
                .padding(.horizontal, 24)
                .background(
                    // 让胶囊浮起来时底下有渐变兜底，滚动的文字不会直接顶到胶囊边缘
                    LinearGradient(
                        colors: [Theme.background.opacity(0), Theme.background],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .padding(.top, -12)
                    .allowsHitTesting(false)
                )
        }
        .background(Theme.background.ignoresSafeArea())
    }
}

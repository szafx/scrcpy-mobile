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

    /// 投屏已收起（画面隐藏、连接保持）→ 各标签页顶部显示「回到画面」横幅
    var isStreamCollapsed: Bool = false
    var streamingDeviceName: String? = nil
    var onReturnToStream: () -> Void = {}

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
        // 投屏收起后，三个标签页共用同一条「回到画面」细横幅
        .safeAreaInset(edge: .top, spacing: 0) {
            if isStreamCollapsed, let name = streamingDeviceName {
                StreamBanner(name: name, action: onReturnToStream)
            }
        }
        // 浮动胶囊浮在内容之上，同时把内容的安全区往上顶，
        // 免得列表最后一行被它盖住。
        // 注意：VRLink 在工具子页里也照样显示这条 —— 所以这里不区分层级。
        // ★ 只保留胶囊本身：外面那层整条渐变/卡片背景已去掉（用户 2026-10-18 指定
        //   —— dock 后面不要那块透明方形卡片，直接让内容透上来）。
        .safeAreaInset(edge: .bottom, spacing: 0) {
            FloatingTabBar(selected: $selectedTab, tabs: tabs)
                .padding(.top, 8)
                .padding(.bottom, 4)
                .padding(.horizontal, 24)
        }
        .background(Theme.background.ignoresSafeArea())
    }
}

// MARK: - 「正在投屏 · 回到画面」横幅

private struct StreamBanner: View {
    let name: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text("正在投屏 \(name) · 点此回到画面")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .opacity(0.85)
            }
            .foregroundColor(.white)
            .padding(.horizontal, Theme.pagePadding)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(Theme.accent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("回到投屏画面")
    }
}

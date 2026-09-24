//
//  ConsoleView.swift
//  Scrcpy Remote
//
//  第二个 Tab：选中设备后的工具箱。对应 VRLink 截图 `shots/00.jpg` 的 Console 页
//  —— 顶部设备卡 + 「Tools」小标题 + 工具网格（手机 2 列 / iPad 单列紧凑行）。
//
//  9 个入口里，「Screen mirror」就是原本那套连接流程（`SessionConnectionManager`），
//  其余 8 个是这一轮新加的工具页。
//

import SwiftUI

struct ConsoleView: View {

    @Binding var savedSessions: [ScrcpySession]
    var onConnectSession: (ScrcpySession) -> Void = { _ in }

    @ObservedObject private var connectionManager = SessionConnectionManager.shared
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var androidVersion: String?
    @State private var isSwitchingDevice = false

    private let service = AdbToolService.shared

    private var tools: [ConsoleTool] {
        [
            ConsoleTool(index: 0,
                        title: "Device info",
                        subtitle: "OS, CPU, display, battery, storage…",
                        icon: "info.circle.fill",
                        kind: .push(AnyView(DeviceInfoView()))),

            ConsoleTool(index: 1,
                        title: "Apps",
                        subtitle: "List apps; uninstall, force stop, or launch.",
                        icon: "square.grid.2x2.fill",
                        kind: .push(AnyView(AppsView()))),

            ConsoleTool(index: 2,
                        title: "Files",
                        subtitle: "Browse device storage; upload or download.",
                        icon: "folder.fill",
                        kind: .push(AnyView(FilesView()))),

            ConsoleTool(index: 3,
                        title: "Screen mirror",
                        subtitle: "Live mirror with touch control.",
                        icon: "rectangle.on.rectangle",
                        kind: .mirror),

            ConsoleTool(index: 4,
                        title: "Screen snapshot",
                        subtitle: "Screencap and MP4 recording.",
                        icon: "camera.viewfinder",
                        kind: .push(AnyView(ComingSoonView(
                            title: "Screen snapshot",
                            note: "截屏与 MP4 录制安排在下一次构建。")))),

            ConsoleTool(index: 5,
                        title: "Quick input",
                        subtitle: "Send text and common remote keys.",
                        icon: "keyboard",
                        kind: .push(AnyView(ComingSoonView(
                            title: "Quick input",
                            note: "文字与遥控键安排在下一次构建。")))),

            ConsoleTool(index: 6,
                        title: "ADB shell",
                        subtitle: "Run presets and custom shell commands.",
                        icon: "terminal.fill",
                        kind: .push(AnyView(ComingSoonView(
                            title: "ADB shell",
                            note: "命令台安排在下一次构建。")))),

            ConsoleTool(index: 7,
                        title: "Logs",
                        subtitle: "Live logcat with level filters.",
                        icon: "doc.text.magnifyingglass",
                        kind: .push(AnyView(ComingSoonView(
                            title: "Logs",
                            note: "logcat 安排在下一次构建。")))),

            ConsoleTool(index: 8,
                        title: "Actions",
                        subtitle: "Saved command sequences for this device.",
                        icon: "play.square.stack.fill",
                        kind: .push(AnyView(ActionsView()))),
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                deviceCard

                HStack(alignment: .firstTextBaseline) {
                    Text("Tools")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.secondaryText)
                    Spacer()
                    Text("For authorized devices only.")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.secondaryText)
                }

                if isConnected {
                    toolGrid
                } else {
                    EmptyStateView(
                        icon: "rectangle.slash",
                        title: "No connected device",
                        message: "Connect an Android device on the Devices tab first."
                    )
                }
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationBarHidden(true)
        .sheet(isPresented: $isSwitchingDevice) {
            deviceSwitcher
        }
        .onAppear { loadAndroidVersion() }
        .onChange(of: connectionManager.currentSession?.id) { _ in
            androidVersion = nil
            loadAndroidVersion()
        }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack {
            Text("Console")
                .font(.system(size: 32, weight: .bold))
            Spacer()
            CircleIconButton(icon: "rectangle.stack.fill") {
                isSwitchingDevice = true
            }
        }
    }

    private var currentSession: ScrcpySessionModel? {
        connectionManager.currentSession
    }

    private var isConnected: Bool {
        connectionManager.currentSession != nil && connectionManager.connectionStatus.isActive
    }

    private var deviceCard: some View {
        CardContainer(padding: 14) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(hex: 0x3DDC84).opacity(0.16))
                    Image("android")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 26, height: 26)
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 4) {
                    Text(currentSession?.sessionName.isEmpty == false
                         ? (currentSession?.sessionName ?? "")
                         : (currentSession?.hostReal ?? "No device"))
                        .font(.system(size: 16, weight: .bold))
                        .lineLimit(1)

                    if let session = currentSession {
                        Text("\(session.hostReal):\(session.port)")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.secondaryText)
                            .lineLimit(1)
                    }

                    StatusPill(
                        text: statusText,
                        kind: statusKind
                    )
                    .padding(.top, 1)
                }

                Spacer(minLength: 4)

                VStack(alignment: .trailing, spacing: 6) {
                    Text(androidVersion ?? "—")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.secondaryText)
                    if connectionManager.isUsingFrp {
                        Text("frp")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Theme.accent)
                    } else if connectionManager.isUsingTailscale {
                        Text("Tailscale")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Theme.accent)
                    } else if isConnected {
                        Text("LAN")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Theme.accent)
                    }
                }
            }
        }
    }

    private var statusText: String {
        if connectionManager.isConnecting { return "Connecting" }
        guard isConnected else { return "Idle" }
        switch connectionManager.connectionStatus {
        case ScrcpyStatusConnectingFailed: return "Failed"
        case ScrcpyStatusConnected, ScrcpyStatusSDLWindowAppeared: return "Connected"
        default: return "Connecting"
        }
    }

    private var statusKind: StatusPillKind {
        if connectionManager.isConnecting { return .warning }
        guard isConnected else { return .idle }
        switch connectionManager.connectionStatus {
        case ScrcpyStatusConnectingFailed: return .danger
        case ScrcpyStatusConnected, ScrcpyStatusSDLWindowAppeared: return .connected
        default: return .warning
        }
    }

    // MARK: - 工具网格

    private var toolGrid: some View {
        let isCompact = sizeClass == .compact

        return Group {
            if isCompact {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: Theme.gridSpacing),
                              GridItem(.flexible(), spacing: Theme.gridSpacing)],
                    spacing: Theme.gridSpacing
                ) {
                    ForEach(tools) { tool in
                        ToolCell(tool: tool, compact: true, onMirror: startMirror)
                    }
                }
            } else {
                LazyVStack(spacing: Theme.gridSpacing) {
                    ForEach(tools) { tool in
                        ToolCell(tool: tool, compact: false, onMirror: startMirror)
                    }
                }
            }
        }
    }

    private func startMirror() {
        guard let model = currentSession else { return }
        onConnectSession(ScrcpySession(sessionModel: model))
    }

    // MARK: - 切换设备

    private var deviceSwitcher: some View {
        NavigationView {
            List {
                if savedSessions.isEmpty {
                    Text("No saved devices.")
                        .foregroundColor(Theme.secondaryText)
                }
                ForEach(savedSessions) { session in
                    Button {
                        isSwitchingDevice = false
                        onConnectSession(session)
                    } label: {
                        HStack {
                            Image(systemName: "iphone")
                                .foregroundColor(Theme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.title)
                                    .foregroundColor(.primary)
                                Text("\(session.sessionModel.hostReal):\(session.sessionModel.port)")
                                    .font(.system(size: 12))
                                    .foregroundColor(Theme.secondaryText)
                            }
                            Spacer()
                            if connectionManager.currentSession?.id == session.sessionModel.id {
                                Image(systemName: "checkmark")
                                    .foregroundColor(Theme.accent)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationBarTitle("Switch device", displayMode: .inline)
            .navigationBarItems(trailing: Button("Done") { isSwitchingDevice = false })
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    // MARK: - Android 版本

    private func loadAndroidVersion() {
        guard isConnected, service.isReady else { return }
        Task {
            let result = await service.shell("getprop ro.build.version.release")
            let value = result.trimmed
            await MainActor.run {
                androidVersion = value.isEmpty ? nil : "Android \(value)"
            }
        }
    }
}

// MARK: - 工具定义

struct ConsoleTool: Identifiable {
    let index: Int
    // 文字用 key，才会查 Localizable.strings（见 Components.swift 的说明）
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let icon: String

    enum Kind {
        /// 推一个新页面。
        case push(AnyView)
        /// 启动投屏（走会话连接流程）。
        case mirror
    }

    let kind: Kind
    var id: Int { index }
}

private struct ToolCell: View {
    let tool: ConsoleTool
    let compact: Bool
    let onMirror: () -> Void

    var body: some View {
        Group {
            switch tool.kind {
            case .push(let destination):
                NavigationLink(destination: destination) {
                    label
                }
                .buttonStyle(.plain)
            case .mirror:
                Button(action: onMirror) {
                    label
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ToolIcon(systemName: tool.icon, color: Theme.toolColor(index: tool.index))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.secondaryText)
            }

            Text(tool.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)

            Text(tool.subtitle)
                .font(.system(size: 12))
                .foregroundColor(Theme.secondaryText)
                .lineLimit(compact ? 3 : 2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(Theme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .stroke(Theme.separator, lineWidth: 0.5)
        )
    }
}

// MARK: - 占位页

/// 还没实现的工具页。写着进度，别让用户以为是坏了。
struct ComingSoonView: View {
    let title: LocalizedStringKey
    let note: LocalizedStringKey

    var body: some View {
        VStack {
            EmptyStateView(
                icon: "hammer",
                title: title,
                message: note
            )
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
        .navigationBarTitle(title, displayMode: .inline)
    }
}

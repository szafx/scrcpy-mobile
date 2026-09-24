//
//  DevicesView.swift
//  Scrcpy Remote
//
//  第一个 Tab：设备列表。对应 VRLink 截图 `shots/00.jpg` 的 Devices 页。
//
//  数据仍然来自 `SessionManager`（Keychain 里的 [ScrcpySessionModel]），
//  连接仍然走 `SessionConnectionManager.connectToSession` —— 这一页只换了皮，
//  没有自己的一套状态。
//

import SwiftUI

struct DevicesView: View {
    @Binding var savedSessions: [ScrcpySession]

    @ObservedObject private var connectionManager = SessionConnectionManager.shared

    var onConnectSession: (ScrcpySession) -> Void = { _ in }
    var onDeleteSession: (UUID) -> Void = { _ in }
    var onEditSession: (ScrcpySession) -> Void = { _ in }
    var onDuplicateSession: (ScrcpySession) -> Void = { _ in }
    var onCreateSession: () -> Void = {}
    var onOpenSettings: () -> Void = {}

    @State private var isLanScanPresented = false
    @State private var sessionPendingDeletion: ScrcpySession?
    @State private var showDeleteConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {

                HStack {
                    Text("Devices")
                        .font(.system(size: 32, weight: .bold))
                    Spacer()
                    CircleIconButton(icon: "plus", action: onCreateSession)
                }

                HeroCard(
                    icon: "wifi",
                    title: "Scrcpy Remote",
                    subtitle: "Control your Android devices over Wi-Fi, the frp tunnel, or Tailscale — no desktop required."
                )

                quickEntries

                if savedSessions.isEmpty {
                    EmptyStateView(
                        icon: "rectangle.stack.badge.plus",
                        title: "No devices yet",
                        message: "Tap + to add a device: pairing code, LAN scan, or manual IP / port."
                    ) {
                        PrimaryButton(title: "Scan LAN", icon: "dot.radiowaves.left.and.right") {
                            isLanScanPresented = true
                        }
                        .padding(.horizontal, 32)
                    }
                } else {
                    deviceList
                }
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationBarHidden(true)
        .sheet(isPresented: $isLanScanPresented) {
            LanScanSheet(
                onPick: { host, port in
                    isLanScanPresented = false
                    // 用「编辑」那条 sheet 打开一个**新建**的模型：
                    // SessionCreateView(sessionModel:) 会把它预填好，用户确认后
                    // SessionManager.saveSession 按 id upsert，等价于新建。
                    onEditSession(ScrcpySession(sessionModel: ScrcpySessionModel(host: host, port: port)))
                },
                onManual: {
                    isLanScanPresented = false
                    onCreateSession()
                }
            )
        }
        .alert(isPresented: $showDeleteConfirm) {
            Alert(
                title: Text("Delete Device"),
                message: Text("Remove “\(sessionPendingDeletion?.title ?? "")” from the list? This won't touch the Android device itself."),
                primaryButton: .destructive(Text("Delete")) {
                    if let s = sessionPendingDeletion { onDeleteSession(s.id) }
                    sessionPendingDeletion = nil
                },
                secondaryButton: .cancel { sessionPendingDeletion = nil }
            )
        }
    }

    // MARK: - 三个快捷入口

    private var quickEntries: some View {
        HStack(spacing: 10) {
            // ADBPairingView 自己不带导航标题（它本来挂在 SettingsView 的 NavigationLink 下），
            // 这里推它进去时补一个 —— 顺带保证它一定有导航栏和返回按钮。
            NavigationLink(destination: ADBPairingView()
                .navigationBarTitle("Pair with code", displayMode: .inline)) {
                QuickEntryLabel(icon: "number.square", title: "Pair with code")
            }
            .buttonStyle(.plain)

            QuickEntryButton(icon: "dot.radiowaves.left.and.right", title: "Scan LAN") {
                isLanScanPresented = true
            }

            QuickEntryButton(icon: "keyboard", title: "Manual") {
                onCreateSession()
            }
        }
    }

    // MARK: - 设备列表

    private var deviceList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Saved devices")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.secondaryText)
                .textCase(nil)

            ForEach(savedSessions) { session in
                DeviceRow(
                    session: session,
                    status: statusText(for: session),
                    kind: statusKind(for: session),
                    isActive: isActive(session),
                    isBusy: connectionManager.isConnecting,
                    onConnect: { onConnectSession(session) },
                    onDisconnect: { SessionConnectionManager.shared.disconnectCurrent() },
                    onEdit: { onEditSession(session) },
                    onDuplicate: { onDuplicateSession(session) },
                    onDelete: {
                        sessionPendingDeletion = session
                        showDeleteConfirm = true
                    }
                )
            }
        }
    }

    // MARK: - 状态推导

    /// 这台设备是不是「当前会话」。
    private func isActive(_ session: ScrcpySession) -> Bool {
        guard let current = connectionManager.currentSession else { return false }
        return current.id == session.sessionModel.id
    }

    private func statusText(for session: ScrcpySession) -> String {
        guard isActive(session) else { return "Idle" }
        if connectionManager.isConnecting { return "Connecting" }
        switch connectionManager.connectionStatus {
        case ScrcpyStatusConnected, ScrcpyStatusSDLWindowAppeared:
            return "Connected"
        case ScrcpyStatusConnectingFailed:
            return "Failed"
        case ScrcpyStatusDisconnected:
            return "Idle"
        default:
            return "Connecting"
        }
    }

    private func statusKind(for session: ScrcpySession) -> StatusPillKind {
        guard isActive(session) else { return .idle }
        if connectionManager.isConnecting { return .warning }
        switch connectionManager.connectionStatus {
        case ScrcpyStatusConnected, ScrcpyStatusSDLWindowAppeared:
            return .connected
        case ScrcpyStatusConnectingFailed:
            return .danger
        case ScrcpyStatusDisconnected:
            return .idle
        default:
            return .warning
        }
    }
}

// MARK: - 一行设备

private struct DeviceRow: View {
    let session: ScrcpySession
    let status: String
    let kind: StatusPillKind
    let isActive: Bool
    let isBusy: Bool
    let onConnect: () -> Void
    let onDisconnect: () -> Void
    let onEdit: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color(hex: 0x3DDC84).opacity(0.16))
                Image("android")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 22)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 3) {
                Text(session.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Text("\(session.sessionModel.hostReal):\(session.sessionModel.port)")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.secondaryText)
                    .lineLimit(1)

                StatusPill(text: status, kind: kind)
                    .padding(.top, 1)
            }

            Spacer(minLength: 6)

            if isActive {
                Button(action: onDisconnect) {
                    Text("Disconnect")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.dangerForeground)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            Capsule(style: .continuous)
                                .stroke(Theme.dangerForeground.opacity(0.5), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            } else {
                Button(action: onConnect) {
                    Text("Connect")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            Capsule(style: .continuous).fill(Theme.accent)
                        )
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
                .opacity(isBusy ? 0.5 : 1)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(Theme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .stroke(Theme.separator, lineWidth: 0.5)
        )
        .contextMenu {
            Button { onConnect() } label: { Label("Connect", systemImage: "bolt.horizontal") }
            Button { onEdit() } label: { Label("Edit", systemImage: "pencil") }
            Button { onDuplicate() } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            Button { onDelete() } label: { Label("Delete", systemImage: "trash") }
        }
    }
}

// MARK: - 局域网扫描

/// 扫本机网段找开着的 adb 端口（5555）。
///
/// 底层就是 `LanDiscovery.discover()` —— 连接时自动发现用的同一个函数，
/// 这里只是把结果摆出来让用户挑，省得手敲 IP。
struct LanScanSheet: View {
    var onPick: (String, String) -> Void
    var onManual: () -> Void

    @Environment(\.presentationMode) private var presentationMode
    @State private var isScanning = false
    @State private var hosts: [String] = []
    @State private var hasScanned = false

    var body: some View {
        NavigationView {
            List {
                Section {
                    Text("Scans this iPhone's Wi-Fi subnet for Android devices listening on the ADB port (5555).")
                        .font(.footnote)
                        .foregroundColor(Theme.secondaryText)
                }

                if isScanning {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Scanning…")
                            .foregroundColor(Theme.secondaryText)
                    }
                }

                if hasScanned && hosts.isEmpty && !isScanning {
                    Text("No devices found. Make sure the phone is on the same Wi-Fi and wireless debugging (adb tcpip 5555) is on.")
                        .font(.footnote)
                        .foregroundColor(Theme.secondaryText)
                }

                if !hosts.isEmpty {
                    Section(header: Text("Found")) {
                        ForEach(hosts, id: \.self) { host in
                            Button {
                                onPick(host, "5555")
                            } label: {
                                HStack {
                                    Image(systemName: "iphone.gen3")
                                    Text(host)
                                    Spacer()
                                    Text("Add")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(Theme.accent)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationBarTitle("Scan LAN", displayMode: .inline)
            .navigationBarItems(
                leading: Button("Manual") { onManual() },
                trailing: Button("Done") { presentationMode.wrappedValue.dismiss() }
            )
            .onAppear { if !hasScanned { scan() } }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func scan() {
        isScanning = true
        hasScanned = false
        Task {
            let found = await LanDiscovery.discover()
            await MainActor.run {
                hosts = found.map { $0.host }
                isScanning = false
                hasScanned = true
            }
        }
    }
}

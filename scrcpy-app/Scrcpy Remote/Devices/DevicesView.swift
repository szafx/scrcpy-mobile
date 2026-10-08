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
    /// ★ 点选直连：把预填好的临时会话模型交出去，弹「连接设置」页（跟普通会话同款编辑页），
    ///   设完点「连接」直接连、不落盘。见 SessionCreateView.onConnect。
    var onQuickConnectModel: (ScrcpySessionModel) -> Void = { _ in }

    @State private var isLanScanPresented = false
    @State private var sessionPendingDeletion: ScrcpySession?
    @State private var showDeleteConfirm = false

    // ★ 「发现设备」点选直连（临时会话）的屏幕选项：连接后是否关闭对方屏幕。
    //   默认 **关**（被控端保持亮屏）—— 电视/临时看一眼时最不意外；
    //   要省电（批量手机）在扫描页里打开一次即记住（同一个 key）。
    @AppStorage("quickConnect.turnScreenOff") private var quickTurnScreenOff = false

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
                onConnect: { device, name in
                    isLanScanPresented = false
                    // ★ 点列表即连：构造一个**临时会话**（不落盘）。
                    //   · sessionName 用用户起的名字（没起过就用「型号 · 后4位」）
                    //   · frpProxyName 必填 —— 它既是 frp visitor 的 proxy 名，
                    //     也是局域网匹配的「设备身份」（后缀 = 序列号后4位）
                    //   · useFrp 只有「这台挂着 frpc」才开；连接时依旧走既有的
                    //     三级选路：局域网能匹配上就走局域网 → frp(P2P) → 中转
                    var model = ScrcpySessionModel()
                    model.host = device.lanHost ?? FrpSettings.load().serverAddr
                    model.port = "5555"
                    model.sessionName = name
                    model.useFrp = device.canFrp
                    model.frpProxyName = device.frpProxyName ?? "phone-\(device.model)-\(device.suffix)"
                    // 临时会话的屏幕选项：默认保持亮屏（见 quickTurnScreenOff 的说明），
                    // 开关在扫描页顶部，改一次即记住；进「连接设置」页后还能改全部参数。
                    model.adbOptions.turnScreenOff = quickTurnScreenOff
                    // ★ 不再直接连 —— 打开和普通会话同款的「连接设置」页（预填），
                    //   画质/帧数/码率/音频/熄屏……全部可调，点「连接」即连、不落盘。
                    onQuickConnectModel(model)
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

                StatusPill(text: LocalizedStringKey(status), kind: kind)
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
    var onConnect: (DiscoveredDevice, String) -> Void
    var onManual: () -> Void

    @Environment(\.presentationMode) private var presentationMode
    @StateObject private var discovery = DeviceDiscovery()
    @State private var adminUser = ""
    @State private var adminPass = ""
    @State private var renameTarget: DiscoveredDevice? = nil
    @State private var renameText = ""

    // 与 DevicesView 共用同一个 key：点选直连的临时会话「连上后是否熄屏」
    @AppStorage("quickConnect.turnScreenOff") private var quickTurnScreenOff = false

    var body: some View {
        NavigationView {
            List {
                Section {
                    HStack(spacing: 10) {
                        ProgressView().opacity(discovery.running ? 1 : 0)
                        Text(LocalizedStringKey(discovery.phase.isEmpty ? "Ready" : discovery.phase))
                            .font(.footnote)
                            .foregroundColor(Theme.secondaryText)
                    }
                }

                Section {
                    Toggle("Turn Remote Screen Off After Connected", isOn: $quickTurnScreenOff)
                    Text("关 = 被控端保持亮屏（电视等场景）；开 = 连上后熄屏省电。只影响「点选直连」的临时会话，改一次即记住。")
                        .font(.footnote)
                        .foregroundColor(Theme.secondaryText)
                }

                if let frpError = discovery.frpError {
                    Section(header: Text("frpc online list")) {
                        if frpError == "need frps admin account" {
                            Text("Enter the frps admin account (webServer) to list online devices — saved once, used for every scan.")
                                .font(.footnote)
                                .foregroundColor(Theme.secondaryText)
                            TextField("frps admin user", text: $adminUser)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                            SecureField("frps admin password", text: $adminPass)
                            Button("Save") {
                                FrpSettings.saveAdmin(user: adminUser, pass: adminPass)
                                Task { await discovery.run() }
                            }
                            .disabled(adminUser.isEmpty || adminPass.isEmpty)
                        } else {
                            Text(LocalizedStringKey(frpError))
                                .font(.footnote)
                                .foregroundColor(Theme.secondaryText)
                        }
                    }
                }

                if !discovery.devices.isEmpty {
                    Section(header: Text("Found")) {
                        ForEach(discovery.devices) { device in
                            Button {
                                onConnect(device, discovery.name(for: device))
                            } label: {
                                HStack {
                                    Image(systemName: "iphone.gen3")
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(discovery.name(for: device))
                                        Text(LocalizedStringKey(subtitle(device)))
                                            .font(.footnote)
                                            .foregroundColor(Theme.secondaryText)
                                    }
                                    Spacer()
                                    HStack(spacing: 6) {
                                        if device.canLan { DiscoveryBadge(text: "LAN", color: .green) }
                                        if device.canFrp { DiscoveryBadge(text: "frpc", color: .blue) }
                                    }
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button {
                                    beginRename(device)
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                .tint(.orange)
                            }
                            .contextMenu {
                                Button {
                                    beginRename(device)
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                            }
                        }
                    }
                }

                if !discovery.running, discovery.devices.isEmpty, !discovery.phase.isEmpty,
                   discovery.phase != "Ready", discovery.phase != "Done" {
                    Text("No devices found. Make sure the phone is on the same Wi-Fi (adb tcpip 5555) or frpc is online.")
                        .font(.footnote)
                        .foregroundColor(Theme.secondaryText)
                }
            }
            .listStyle(.insetGrouped)
            .navigationBarTitle("Discover Devices", displayMode: .inline)
            .navigationBarItems(
                leading: Button("Manual") { onManual() },
                trailing: HStack(spacing: 12) {
                    Button("Rescan") { Task { await discovery.run() } }
                        .disabled(discovery.running)
                    Button("Done") { presentationMode.wrappedValue.dismiss() }
                }
            )
            .onAppear {
                let saved = FrpSettings.load()
                adminUser = saved.adminUser
                adminPass = saved.adminPass
                Task { await discovery.run() }
            }
            .alert("Rename Device", isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )) {
                TextField("Device name", text: $renameText)
                Button("Save") {
                    if let target = renameTarget {
                        discovery.rename(target, to: renameText)
                    }
                    renameTarget = nil
                }
                Button("Cancel", role: .cancel) { renameTarget = nil }
            } message: {
                Text("Remembered for this device (model + serial suffix). Leave empty to reset.")
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func beginRename(_ device: DiscoveredDevice) {
        renameTarget = device
        renameText = discovery.customNames[device.id] ?? ""
    }

    /// 副标题：局域网就显示地址；只有 frpc 就说明走隧道
    private func subtitle(_ device: DiscoveredDevice) -> String {
        if let host = device.lanHost { return host }
        return "via frpc tunnel"
    }
}

private struct DiscoveryBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .cornerRadius(6)
    }
}

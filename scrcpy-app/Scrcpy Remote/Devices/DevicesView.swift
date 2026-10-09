//
//  DevicesView.swift
//  Scrcpy Remote
//
//  第一个 Tab：设备首页（2026-10-09 重做）。
//
//  新版设计（用户定的）：
//    · **扫描进首页** —— 不再有「Scan LAN」按钮和扫描 sheet；页面自己定时跑发现。
//    · **统一列表** —— 「扫描到过的 + 已保存的」全部列在一起（同一台合并成一行）。
//    · **四路状态灯** —— 每行下面四个小灯：局域网 / 中转 / 打洞 / TS，
//      绿 = 当前这条能走通，灰 = 走不通；全都灰也照常显示（离线设备不消失）。
//    · 实时刷新分两层（见 DeviceDiscovery）：
//        - frps 名单 + tailnet 探针 + 已知地址存活：8 秒一轮（便宜）
//        - 全子网扫描：只在进页面 / 下拉刷新时跑（耗电且会弄脏 adb 设备表）
//
//  设置页复用：点「没保存过的设备」→ 弹「连接设置」（临时会话，不落盘，
//  见 SessionCreateView.onConnect 与 SessionSheet 的说明）。
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

    @EnvironmentObject var appSettings: AppSettings

    /// 设置 sheet 里显示哪一页：quickConnect = 点选直连的「连接设置」（临时、不落盘）；
    /// createSession = 新建会话。nil 时 sheet 不显示。
    /// ★ 扫到的列表已并入首页，sheet 只用来承载设置页本身。
    private enum ScanSheetMode {
        case quickConnect(ScrcpySessionModel)
        case createSession
    }

    @State private var isScanSheetShown = false
    @State private var scanSheetMode: ScanSheetMode? = nil
    @State private var sessionPendingDeletion: ScrcpySession?
    @State private var showDeleteConfirm = false
    @State private var renameTarget: DiscoveredDevice? = nil
    @State private var renameText = ""
    @State private var adminUser = ""
    @State private var adminPass = ""

    @StateObject private var discovery = DeviceDiscovery()

    // ★ 「点选直连」临时会话的屏幕选项：连接后是否关闭对方屏幕。
    //   默认 **关**（被控端保持亮屏）；要省电在首页开关里打开一次即记住。
    @AppStorage("quickConnect.turnScreenOff") private var quickTurnScreenOff = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                quickEntries
                discoveryBar
                deviceList
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationBarHidden(true)
        // 下拉 = 全量重扫（含 253 地址大扫描；平时是 8 秒一轮的轻量刷新）
        .refreshable { await discovery.run() }
        .task {
            // 进页面全量发现一次（走共享扫描缓存，通常很快），
            // 之后每 8 秒轻量刷新（frps 名单 + tailnet 探针 + 已知地址存活）。
            await discovery.run()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                await discovery.refreshLightweight()
            }
        }
        .sheet(isPresented: $isScanSheetShown, onDismiss: {
            scanSheetMode = nil
        }) {
            switch scanSheetMode {
            case .quickConnect(let model):
                SessionCreateView(sessionModel: model, onConnect: { m in
                    isScanSheetShown = false
                    onConnectSession(ScrcpySession(sessionModel: m))
                })
                .environmentObject(appSettings)

            case .createSession:
                SessionCreateView()
                    .environmentObject(appSettings)

            case nil:
                EmptyView()
            }
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
        .alert("重命名设备", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("设备名", text: $renameText)
            Button("保存") {
                if let target = renameTarget {
                    discovery.rename(target, to: renameText)
                }
                renameTarget = nil
            }
            Button("取消", role: .cancel) { renameTarget = nil }
        } message: {
            Text("按「型号 + 序列号后4位」记住这台设备。留空 = 恢复默认名。")
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack {
            Text("Devices")
                .font(.system(size: 32, weight: .bold))
            Spacer()
            CircleIconButton(icon: "plus", action: onCreateSession)
        }
    }

    // MARK: - 快捷入口（Scan LAN 已并入首页，不再单独给按钮）

    private var quickEntries: some View {
        HStack(spacing: 10) {
            NavigationLink(destination: ADBPairingView()
                .navigationBarTitle("Pair with code", displayMode: .inline)) {
                QuickEntryLabel(icon: "number.square", title: "Pair with code")
            }
            .buttonStyle(.plain)

            QuickEntryButton(icon: "keyboard", title: "Manual") {
                onCreateSession()
            }
        }
    }

    // MARK: - 扫描状态条（阶段提示 + 熄屏开关 + frps 账户回退）

    private var discoveryBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if discovery.running {
                    ProgressView().scaleEffect(0.7)
                }
                Text(discovery.running
                     ? LocalizedStringKey(discovery.phase.isEmpty ? "Scanning…" : discovery.phase)
                     : LocalizedStringKey(discovery.phase.isEmpty ? "下拉可重新扫描" : discovery.phase))
                    .font(.footnote)
                    .foregroundColor(Theme.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Toggle("连后熄屏", isOn: $quickTurnScreenOff)
                    .font(.footnote)
                    .fixedSize()
            }

            if discovery.frpError == "need frps admin account" {
                Text("填一次 frps 管理账号（拉「哪些手机挂着 frpc」用，存本机）：")
                    .font(.footnote)
                    .foregroundColor(Theme.secondaryText)
                HStack(spacing: 8) {
                    TextField("frps user", text: $adminUser)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .font(.footnote)
                    SecureField("password", text: $adminPass)
                        .font(.footnote)
                    Button("保存") {
                        FrpSettings.saveAdmin(user: adminUser, pass: adminPass)
                        Task { await discovery.run() }
                    }
                    .font(.footnote)
                    .disabled(adminUser.isEmpty || adminPass.isEmpty)
                }
            } else if let e = discovery.frpError, e != "frps not configured" {
                Text(LocalizedStringKey("frpc 名单不可用：\(e)"))
                    .font(.footnote)
                    .foregroundColor(Theme.secondaryText)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - 统一设备列表（扫描到的 + 已保存的）

    private var deviceList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("设备（\(homeRows.count)）")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.secondaryText)
                .textCase(nil)

            if homeRows.isEmpty && !discovery.running {
                Text("还没发现设备。确保手机在同一个 WiFi（开着 adb tcpip 5555），或者它挂着 frpc 在线；下拉可重新扫描。")
                    .font(.footnote)
                    .foregroundColor(Theme.secondaryText)
                    .padding(.vertical, 12)
            }

            ForEach(homeRows) { row in
                HomeDeviceRow(
                    row: row,
                    isActive: row.session.map { isActive($0) } ?? false,
                    isBusy: connectionManager.isConnecting,
                    onOpen: { openQuickConnect(for: row) },
                    onConnect: { if let s = row.session { onConnectSession(s) } },
                    onDisconnect: { SessionConnectionManager.shared.disconnectCurrent() },
                    onEdit: { if let s = row.session { onEditSession(s) } },
                    onDuplicate: { if let s = row.session { onDuplicateSession(s) } },
                    onDelete: {
                        if let s = row.session {
                            sessionPendingDeletion = s
                            showDeleteConfirm = true
                        }
                    },
                    onRename: {
                        if let d = row.discovered {
                            renameTarget = d
                            renameText = discovery.customNames[d.id] ?? ""
                        }
                    }
                )
            }
        }
    }

    // MARK: - 合并行（已保存会话 ∪ 发现结果）

    struct HomeRow: Identifiable {
        let id: String
        var title: String
        var subtitle: String
        var status: String       // Idle / Connecting / Connected / Failed / 新发现
        var statusKind: StatusPillKind
        var lanOn: Bool          // 局域网灯
        var relayOn: Bool        // 家里 IPv6 中转灯
        var p2pOn: Bool          // frpc 打洞灯
        var tsOn: Bool           // Tailscale 灯
        var session: ScrcpySession?
        var discovered: DiscoveredDevice?
    }

    private var homeRows: [HomeRow] {
        var rows: [HomeRow] = []
        var usedDiscoveryIds = Set<String>()

        // ① 已保存的会话先占位（保持原有顺序）
        for session in savedSessions {
            let m = session.sessionModel
            let match = discovery.devices.first { dev in
                if let proxy = dev.frpProxyName, !m.frpProxyName.isEmpty,
                   proxy.caseInsensitiveCompare(m.frpProxyName) == .orderedSame {
                    return true
                }
                if let lan = dev.lanHost, lan == m.hostReal { return true }
                return false
            }
            if let match { usedDiscoveryIds.insert(match.id) }
            rows.append(HomeRow(
                id: "session-\(session.id.uuidString)",
                title: session.title,
                subtitle: "\(m.hostReal):\(m.port)",
                status: statusText(for: session),
                statusKind: statusKind(for: session),
                lanOn: match?.canLan ?? false,
                relayOn: match?.relayReachable ?? false,
                p2pOn: match?.relayReachable ?? false,
                tsOn: match?.tailnetOnline ?? false,
                session: session,
                discovered: match
            ))
        }

        // ② 没被会话覆盖的发现设备补在后面
        for dev in discovery.devices where !usedDiscoveryIds.contains(dev.id) {
            rows.append(HomeRow(
                id: "device-\(dev.id)",
                title: discovery.name(for: dev),
                subtitle: subtitle(for: dev),
                status: "新发现",
                statusKind: .idle,
                lanOn: dev.canLan,
                relayOn: dev.relayReachable,
                p2pOn: dev.relayReachable,
                tsOn: dev.tailnetOnline,
                session: nil,
                discovered: dev
            ))
        }
        return rows
    }

    /// 发现设备的副标题：局域网地址 > frpc 在线 > 离线
    private func subtitle(for dev: DiscoveredDevice) -> String {
        if let host = dev.lanHost { return "\(host):5555" }
        if let proxy = dev.frpProxyName {
            return dev.relayPort.map { "via frpc · 中转口 \($0)" } ?? "via frpc"
        }
        return "未上线"
    }

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

    // MARK: - 点「发现设备」→ 连接设置（临时会话，不落盘）

    private func openQuickConnect(for row: HomeRow) {
        guard let dev = row.discovered else { return }
        var model = ScrcpySessionModel()
        model.host = dev.lanHost ?? FrpSettings.load().serverAddr
        model.port = "5555"
        model.sessionName = discovery.name(for: dev)
        model.useFrp = dev.canFrp
        model.frpProxyName = dev.frpProxyName ?? "phone-\(dev.model)-\(dev.suffix)"
        // 发现到的中转端口直接预填 —— 进设置页选「家里 IPv6 中转」就不用再手敲
        if let rp = dev.relayPort { model.frpRemotePort = String(rp) }
        model.adbOptions.turnScreenOff = quickTurnScreenOff
        // ★ 就地弹设置页（不关不开 —— 同 tick 二次 present 会被 UIKit 吞，见交接-2026-10-09）
        scanSheetMode = .quickConnect(model)
        isScanSheetShown = true
    }
}

// MARK: - 一行设备（统一列表用）

private struct HomeDeviceRow: View {
    let row: DevicesView.HomeRow
    let isActive: Bool
    let isBusy: Bool
    let onOpen: () -> Void
    let onConnect: () -> Void
    let onDisconnect: () -> Void
    let onEdit: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void
    let onRename: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
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
                Text(row.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Text(row.subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.secondaryText)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    StatusPill(text: LocalizedStringKey(row.status), kind: row.statusKind)

                    // 四路状态灯：绿 = 当前可走，灰 = 不可走
                    MethodChip(text: "局域网", on: row.lanOn)
                    MethodChip(text: "中转", on: row.relayOn)
                    MethodChip(text: "打洞", on: row.p2pOn)
                    MethodChip(text: "TS", on: row.tsOn)
                }
                .padding(.top, 1)
            }

            Spacer(minLength: 6)

            if row.session != nil {
                if isActive {
                    Button(action: onDisconnect) {
                        Text("断开")
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
                        Text("连接")
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
            } else {
                // 未保存的发现设备：戳这里进「连接设置」（四路任选）
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15))
                    .foregroundColor(Theme.accent)
                    .padding(6)
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
        .contentShape(Rectangle())
        .onTapGesture {
            if row.discovered != nil { onOpen() }
        }
        .contextMenu {
            if row.discovered != nil {
                Button { onRename() } label: { Label("重命名", systemImage: "pencil") }
            }
            if row.session != nil {
                Button { onConnect() } label: { Label("Connect", systemImage: "bolt.horizontal") }
                Button { onEdit() } label: { Label("编辑（全部参数）", systemImage: "slider.horizontal.3") }
                Button { onDuplicate() } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                Button(role: .destructive) { onDelete() } label: { Label("Delete", systemImage: "trash") }
            }
        }
    }
}

// MARK: - 四路状态灯的小胶囊

private struct MethodChip: View {
    let text: String
    let on: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(on ? Color.green.opacity(0.16) : Color.gray.opacity(0.12))
            )
            .foregroundColor(on ? Color(hex: 0x1E8E3E) : Theme.secondaryText)
            .lineLimit(1)
    }
}

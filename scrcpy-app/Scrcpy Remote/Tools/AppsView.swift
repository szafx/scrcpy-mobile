//
//  AppsView.swift
//  Scrcpy Remote
//
//  Console → Apps：列出 / 搜索 / 启动 / 强停 / 卸载 / 提取 APK / 安装 APK。
//
//  ★ 为什么全是 `pm` / `am` 命令，而不是走一个设备端服务端：
//    VRLink 是用它自带的一个 GPL-3.0 的安卓服务端（`easycontrol_for_car_server`）暴露
//    HTTP 接口来取应用列表的。GPL-3.0 有传染性，不能引。这里全部用标准 `adb shell`，
//    一个字节都不引 —— 代价只有「拿不到 App 真图标」，所以用彩色首字母方块代替
//    （VRLink 的截图里本来也是方块）。
//
//  ★ 为什么不做「按标签名搜索」：Android 的 App 显示名（ApplicationLabel）在 APK 资源里，
//    shell 侧没有批量接口（`dumpsys package` 只给 labelRes 资源 ID，不是文本）。
//    419 个应用逐个 `dumpsys` 太慢。所以列表主标题用包名派生出来的短名，
//    搜索框匹配**包名** —— VRLink 的搜索框占位符本来也写着 "Search package"。
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct AppsView: View {

    enum Filter: String, CaseIterable {
        case all = "All"
        case user = "User"
        case system = "System"
        case launchable = "Launchable"
    }

    @State private var apps: [AppEntry] = []
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var banner: String?
    @State private var query = ""
    @State private var filter: Filter = .all
    @State private var busyPackage: String?
    @State private var isImporting = false
    @State private var detailText: String?
    @State private var showDetail = false

    private let service = AdbToolService.shared

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            filterBar

            if let errorText = errorText {
                bannerView(errorText, color: Theme.warnForeground)
            } else if let banner = banner {
                bannerView(banner, color: Theme.okForeground)
            }

            content
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationBarTitle("Apps", displayMode: .inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    isImporting = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .disabled(!service.isReady)
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { install(url) }
            case .failure(let error):
                errorText = "Pick file failed: \(error.localizedDescription)"
            }
        }
        .alert(isPresented: $showDetail) {
            Alert(title: Text("Package detail"),
                  message: Text(detailText ?? ""),
                  dismissButton: .default(Text("OK")))
        }
        .onAppear { if apps.isEmpty { load() } }
    }

    // MARK: - 顶部控件

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(Theme.secondaryText)
            TextField("Search package", text: $query)
                .autocorrectionDisabled()
                .autocapitalization(.none)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(Theme.secondaryText)
                }
                .buttonStyle(.plain)
            }
            Button {
                load()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .foregroundColor(Theme.accent)
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card)
        )
        .padding(.horizontal, Theme.pagePadding)
        .padding(.top, 8)
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Filter.allCases, id: \.self) { item in
                        FilterChip(title: LocalizedStringKey(item.rawValue), isSelected: filter == item) {
                            filter = item
                        }
                    }
                }
                .padding(.horizontal, Theme.pagePadding)
            }

            Text("\(filteredApps.count) apps")
                .font(.system(size: 12))
                .foregroundColor(Theme.secondaryText)
                .padding(.trailing, Theme.pagePadding)
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func bannerView(_ text: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
            // 提示文案是动态赋值的（"Deleted" / "Copied" …），包成 key 才能翻
            Text(LocalizedStringKey(text))
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundColor(color)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(color.opacity(0.12))
        )
        .padding(.horizontal, Theme.pagePadding)
        .padding(.bottom, 8)
    }

    // MARK: - 列表

    @ViewBuilder
    private var content: some View {
        if isLoading && apps.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text("Reading package list…")
                    .foregroundColor(Theme.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if apps.isEmpty {
            EmptyStateView(
                icon: "square.grid.2x2",
                title: "No packages",
                message: LocalizedStringKey(errorText ?? "Pull to refresh or tap ↻ to retry.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(filteredApps) { app in
                        AppRow(
                            app: app,
                            isBusy: busyPackage == app.package,
                            onLaunch: { launch(app) },
                            onForceStop: { forceStop(app) },
                            onUninstall: { uninstall(app) },
                            onExtract: { extract(app) },
                            onCopy: {
                                UIPasteboard.general.string = app.package
                                banner = "Copied \(app.package)"
                            },
                            onDetail: { showDetails(app) }
                        )
                    }
                }
                .padding(.horizontal, Theme.pagePadding)
                .padding(.bottom, 16)
            }
        }
    }

    private var filteredApps: [AppEntry] {
        var list = apps

        switch filter {
        case .all: break
        case .user: list = list.filter { !$0.isSystem }
        case .system: list = list.filter { $0.isSystem }
        case .launchable: list = list.filter { $0.launchActivity != nil }
        }

        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !trimmed.isEmpty {
            list = list.filter {
                $0.package.lowercased().contains(trimmed)
                    || $0.displayName.lowercased().contains(trimmed)
            }
        }

        return list.sorted { $0.displayName.lowercased() < $1.displayName.lowercased() }
    }

    // MARK: - 取数

    private func load() {
        guard !isLoading else { return }
        isLoading = true
        errorText = nil
        banner = nil

        Task {
            guard service.isReady else {
                await MainActor.run {
                    errorText = service.notReadyReason
                    isLoading = false
                }
                return
            }

            // 三次调用：用户应用 / 系统应用 / 可启动的应用。
            // 分开调是为了拿到 -3 / -s 的分类，合并成一次就分不出用户与系统了。
            async let userResult = service.shell("pm list packages -f -3")
            async let systemResult = service.shell("pm list packages -f -s")
            async let launcherResult = service.shell(
                "cmd package query-activities -a android.intent.action.MAIN -c android.intent.category.LAUNCHER"
            )

            let (user, system, launcher) = await (userResult, systemResult, launcherResult)

            let parsed = Self.buildApps(
                userOutput: user.output,
                systemOutput: system.output,
                launcherOutput: launcher.output
            )

            await MainActor.run {
                isLoading = false
                if parsed.isEmpty {
                    errorText = "No packages returned. \(user.trimmed.prefix(200))"
                } else {
                    apps = parsed
                }
            }
        }
    }

    static func buildApps(userOutput: String, systemOutput: String, launcherOutput: String) -> [AppEntry] {
        var map: [String: AppEntry] = [:]

        func ingest(_ text: String, isSystem: Bool) {
            for line in text.split(separator: "\n") {
                guard let entry = AppEntry(listLine: String(line), isSystem: isSystem) else { continue }
                // 同一个包同时出现在两边时，以「用户应用」为准（更新的系统应用会这样）
                if let existing = map[entry.package] {
                    if isSystem && !existing.isSystem { continue }
                    map[entry.package] = AppEntry(
                        package: entry.package,
                        apkPath: entry.apkPath ?? existing.apkPath,
                        isSystem: entry.isSystem,
                        launchActivity: existing.launchActivity
                    )
                } else {
                    map[entry.package] = entry
                }
            }
        }

        ingest(userOutput, isSystem: false)
        ingest(systemOutput, isSystem: true)

        // `com.pkg/.MainActivity` 或 `com.pkg/com.pkg.MainActivity`
        for line in launcherOutput.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard let slash = text.firstIndex(of: "/") else { continue }

            let package = String(text[text.startIndex..<slash])
            let activity = String(text[text.index(after: slash)...])
            guard package.contains("."), !package.contains(" "), !activity.isEmpty else { continue }

            let component = "\(package)/\(activity)"
            if let existing = map[package] {
                map[package] = AppEntry(
                    package: existing.package,
                    apkPath: existing.apkPath,
                    isSystem: existing.isSystem,
                    launchActivity: component
                )
            }
        }

        return Array(map.values)
    }

    // MARK: - 动作

    private func launch(_ app: AppEntry) {
        guard let activity = app.launchActivity else { return }
        run("Launching \(app.displayName)", command: "am start -n \(activity)", package: app.package)
    }

    private func forceStop(_ app: AppEntry) {
        run("Stopped \(app.displayName)", command: "am force-stop \(app.package)", package: app.package)
    }

    private func uninstall(_ app: AppEntry) {
        // 系统应用只能按用户维度卸载
        let command = app.isSystem
            ? "pm uninstall --user 0 \(app.package)"
            : "pm uninstall \(app.package)"
        run("Uninstalled \(app.displayName)", command: command, package: app.package)
    }

    private func extract(_ app: AppEntry) {
        guard service.isReady else {
            errorText = service.notReadyReason
            return
        }
        extractOnDevice(app)
    }

    private func extractOnDevice(_ app: AppEntry) {
        busyPackage = app.package
        banner = "Locating APK…"
        Task {
            let target = app.package
            let pathResult = await service.shell("pm path \(target)")
            let paths = pathResult.output
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("package:") }
                .map { String($0.dropFirst("package:".count)) }

            guard !paths.isEmpty else {
                await MainActor.run {
                    busyPackage = nil
                    errorText = "No APK path for \(target) (split-APK app?)."
                }
                return
            }

            // 输出目录：Documents/apk/<包名>/
            let folder = service.documentsURL.appendingPathComponent("apk/\(target)", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            var pulled = 0
            for path in paths {
                let name = (path as NSString).lastPathComponent
                let destination = folder.appendingPathComponent(name)
                let result = await service.pull(remotePath: path, localPath: destination.path)
                if result.ok { pulled += 1 }
            }

            await MainActor.run {
                busyPackage = nil
                if pulled > 0 {
                    banner = "Extracted \(pulled) APK file(s) to Documents/apk/\(target)/"
                } else {
                    errorText = "Pull failed for \(target)."
                }
            }
        }
    }

    private func showDetails(_ app: AppEntry) {
        detailText = "Loading…"
        showDetail = true
        Task {
            let result = await service.shell("dumpsys package \(app.package) | grep -E 'versionName|versionCode|firstInstallTime'")
            var text = result.trimmed
            if text.isEmpty { text = "No details returned." }
            if let path = app.apkPath { text += "\n\nAPK: \(path)" }
            text += "\n\nKind: \(app.isSystem ? "System" : "User")"
            text += "\nLaunchable: \(app.launchActivity != nil ? "yes" : "no")"
            let final = text
            await MainActor.run { detailText = final }
        }
    }

    private func run(_ successMessage: String, command: String, package: String) {
        busyPackage = package
        errorText = nil
        banner = nil
        Task {
            let result = await service.shell(command)
            let output = result.trimmed
            await MainActor.run {
                busyPackage = nil
                // `pm uninstall` 成功时回 "Success"，失败回 "Failure [...]"
                if result.ok && !output.lowercased().hasPrefix("failure") {
                    banner = successMessage
                } else {
                    errorText = output.isEmpty ? "Command failed (code \(result.code))" : output
                }
            }
        }
    }

    private func install(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let staging = service.documentsURL.appendingPathComponent("apk-inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let local = staging.appendingPathComponent(url.lastPathComponent)

        do {
            if FileManager.default.fileExists(atPath: local.path) {
                try FileManager.default.removeItem(at: local)
            }
            try FileManager.default.copyItem(at: url, to: local)
        } catch {
            errorText = "Could not read the picked file: \(error.localizedDescription)"
            return
        }

        errorText = nil
        banner = "Pushing \(url.lastPathComponent)…"
        Task {
            let remote = "/data/local/tmp/\(local.lastPathComponent)"
            let pushResult = await service.push(localPath: local.path, remotePath: remote)
            guard pushResult.ok else {
                await MainActor.run { errorText = "Push failed: \(pushResult.trimmed)" }
                return
            }

            await MainActor.run { banner = "Installing…" }
            let installResult = await service.shell("pm install -r \"\(remote)\"")
            let output = installResult.trimmed

            await MainActor.run {
                if output.lowercased().contains("success") {
                    banner = "Installed \(local.lastPathComponent)"
                    apps = []
                    load()
                } else {
                    errorText = output.isEmpty ? "Install failed (code \(installResult.code))" : output
                }
            }
        }
    }
}

// MARK: - 应用条目

struct AppEntry: Identifiable {
    var id: String { package }
    let package: String
    let apkPath: String?
    let isSystem: Bool
    /// `com.pkg/.MainActivity`，没有启动入口时为 nil。
    let launchActivity: String?

    init(package: String, apkPath: String?, isSystem: Bool, launchActivity: String?) {
        self.package = package
        self.apkPath = apkPath
        self.isSystem = isSystem
        self.launchActivity = launchActivity
    }

    /// 解析 `pm list packages -f` 的一行：
    /// `package:/data/app/~~xxx==/com.pkg-yyy==/base.apk=com.pkg`
    ///
    /// 包名取**最后一个** `=` 之后的部分 —— 路径里也可能出现 `=`（`~~xxx==`）。
    init?(listLine: String, isSystem: Bool) {
        let line = listLine.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("package:") else { return nil }
        let body = String(line.dropFirst("package:".count))
        guard let split = body.range(of: "=", options: .backwards) else { return nil }

        let path = String(body[body.startIndex..<split.lowerBound])
        let package = String(body[split.upperBound...])
        guard !package.isEmpty, !package.contains(" ") else { return nil }

        self.package = package
        self.apkPath = path.isEmpty ? nil : path
        self.isSystem = isSystem
        self.launchActivity = nil
    }

    /// 从包名派生一个短名 —— `com.tencent.mm` → `Mm`、`com.ss.android.ugc.aweme` → `Aweme`。
    /// 拼成 `Tencent Mm` 那样太长，所以只取最后一段并首字母大写。
    var displayName: String {
        guard let last = package.split(separator: ".").last else { return package }
        var name = String(last)
        // `com.vivo.video.widget` 这种最后一段还算能看；全小写的做首字母大写
        if name == name.lowercased(), let first = name.first {
            name = String(first).uppercased() + name.dropFirst()
        }
        return name
    }

    /// 首字母方块上显示的 2 个字母。
    var initials: String {
        let letters = displayName.filter { $0.isLetter || $0.isNumber }
        let prefix = String(letters.prefix(2)).uppercased()
        return prefix.isEmpty ? "?" : prefix
    }

    /// 稳定的颜色（同一个包每次进来颜色一致）。
    var colorSeed: Int {
        var hash = 5381
        for byte in package.utf8 {
            hash = ((hash << 5) &+ hash) &+ Int(byte)
        }
        return abs(hash)
    }
}

// MARK: - 一行应用

private struct AppRow: View {
    let app: AppEntry
    let isBusy: Bool
    let onLaunch: () -> Void
    let onForceStop: () -> Void
    let onUninstall: () -> Void
    let onExtract: () -> Void
    let onCopy: () -> Void
    let onDetail: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Theme.toolColor(index: app.colorSeed))
                Text(app.initials)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 3) {
                Text(app.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Text(app.package)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.secondaryText)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    if app.isSystem {
                        StatusPill(text: "System", kind: .idle, showDot: false)
                    } else {
                        StatusPill(text: "User", kind: .connected, showDot: false)
                    }
                    if app.launchActivity != nil {
                        StatusPill(text: "Launchable", kind: .idle, showDot: false)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 1)
            }

            Spacer(minLength: 4)

            if isBusy {
                ProgressView()
            } else {
                Menu {
                    if app.launchActivity != nil {
                        Button { onLaunch() } label: { Label("Open", systemImage: "play.fill") }
                    }
                    Button { onForceStop() } label: { Label("Force stop", systemImage: "stop.circle") }
                    Button { onExtract() } label: { Label("Extract APK", systemImage: "square.and.arrow.down") }
                    Button { onDetail() } label: { Label("Details", systemImage: "info.circle") }
                    Button { onCopy() } label: { Label("Copy package name", systemImage: "doc.on.doc") }
                    Divider()
                    Button(role: .destructive) { onUninstall() } label: {
                        Label("Uninstall", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 20))
                        .foregroundColor(Theme.accent)
                }
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
    }
}

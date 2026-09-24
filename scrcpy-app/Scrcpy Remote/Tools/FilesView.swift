//
//  FilesView.swift
//  Scrcpy Remote
//
//  Console → Files：浏览设备存储 / 上传 / 下载 / 新建目录 / 删除。
//
//  底层就是 `ls -la` + `adb push/pull/rm/mkdir`，没有设备端服务端。
//
//  ★ 两个实测出来的细节：
//    1. 根目录用 `/storage/emulated/0` 而不是 `/sdcard` —— `/sdcard` 是个符号链接，
//       toybox 的 `ls -la /sdcard` **列的是链接本身那一行**，不是目录内容。
//    2. `ls -la` 的一行是「7 个字段 + 文件名」，文件名可以带空格，
//       所以解析必须按空白切成**至多 8 段**，最后一段（含其中的空格）才是名字。
//

import SwiftUI
import UniformTypeIdentifiers

/// 分享面板 和「新建文件夹」共用**一个** sheet 位。
///
/// ★ 同一个视图上挂两个 `.sheet` 时，SwiftUI 只认第一个，第二个静默失效 ——
///   日志里只留一句 `Currently, only presenting a single sheet is supported.`。
///   合并前的症状就是「点新建文件夹没反应」。同 MainContentView 的 `SessionSheet`。
private enum FilesSheet: Identifiable {
    case share
    case newFolder
    var id: String { String(describing: self) }
}

struct FilesView: View {

    /// 默认落地目录。用真实路径，别用 `/sdcard`（符号链接，见文件头注释）。
    private static let storageRoot = "/storage/emulated/0"

    /// 快捷跳转目录。
    ///
    /// ★ 用具名的 struct 而不是 `[(String, String)]` —— Swift **不支持元组元素的 key path**，
    ///   写成元组就没法 `ForEach(..., id: \.0)`。
    struct Shortcut: Identifiable {
        var id: String { label }
        let label: String
        let path: String
    }

    private static let shortcuts: [Shortcut] = [
        Shortcut(label: "Storage", path: storageRoot),
        Shortcut(label: "Download", path: "\(storageRoot)/Download"),
        Shortcut(label: "DCIM", path: "\(storageRoot)/DCIM"),
        Shortcut(label: "Pictures", path: "\(storageRoot)/Pictures"),
        Shortcut(label: "Movies", path: "\(storageRoot)/Movies"),
    ]

    @State private var currentPath = FilesView.storageRoot
    @State private var entries: [FileEntry] = []
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var banner: String?
    @State private var busyName: String?

    @State private var isImporting = false
    @State private var shareItems: [Any] = []

    /// 见文件头的 `FilesSheet` —— 原本是 `isSharing` + `showNewFolderSheet` 两个 bool，
    /// 挂两个 `.sheet` 会让后者永远不显示。
    @State private var activeSheet: FilesSheet? = nil
    @State private var newFolderName = ""

    @State private var pendingDelete: FileEntry?
    @State private var showDeleteConfirm = false

    private let service = AdbToolService.shared

    var body: some View {
        VStack(spacing: 0) {
            pathBar
            shortcutBar
            statusBar
            content
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationBarTitle("Files", displayMode: .inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    isImporting = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
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
                if let url = urls.first { upload(url) }
            case .failure(let error):
                errorText = "Pick file failed: \(error.localizedDescription)"
            }
        }
        // ★ 只留一个 `.sheet` —— 挂两个会让第二个永远不显示（见文件头 FilesSheet）
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .share:     ShareSheet(items: shareItems)
            case .newFolder: newFolderSheet
            }
        }
        .alert(isPresented: $showDeleteConfirm) {
            Alert(
                title: Text("Delete"),
                message: Text("Delete “\(pendingDelete?.name ?? "")” on the device? This cannot be undone."),
                primaryButton: .destructive(Text("Delete")) {
                    if let entry = pendingDelete { delete(entry) }
                    pendingDelete = nil
                },
                secondaryButton: .cancel { pendingDelete = nil }
            )
        }
        .onAppear { if entries.isEmpty { load() } }
    }

    // MARK: - 顶部

    private var pathBar: some View {
        HStack(spacing: 8) {
            Button {
                goUp()
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(parentPath == nil ? Theme.secondaryText : Theme.accent)
            }
            .buttonStyle(.plain)
            .disabled(parentPath == nil)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(currentPath)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }

            Button {
                newFolderName = ""
                activeSheet = .newFolder
            } label: {
                Image(systemName: "folder.badge.plus")
                    .foregroundColor(Theme.accent)
            }
            .buttonStyle(.plain)

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

    private var shortcutBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Self.shortcuts) { item in
                    FilterChip(title: item.label, isSelected: currentPath == item.path) {
                        currentPath = item.path
                        load()
                    }
                }
            }
            .padding(.horizontal, Theme.pagePadding)
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var statusBar: some View {
        if let errorText = errorText {
            messageBanner(errorText, color: Theme.warnForeground)
        } else if let banner = banner {
            messageBanner(banner, color: Theme.okForeground)
        }
    }

    @ViewBuilder
    private func messageBanner(_ text: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
            // 提示文案是动态赋值的（"Deleted" / "Created" …），包成 key 才能翻
            Text(LocalizedStringKey(text))
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundColor(color)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(color.opacity(0.12))
        )
        .padding(.horizontal, Theme.pagePadding)
        .padding(.bottom, 8)
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if isLoading && entries.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text("Listing \(currentPath)…")
                    .foregroundColor(Theme.secondaryText)
                    .font(.system(size: 13))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if entries.isEmpty {
            EmptyStateView(
                icon: "folder",
                title: "Empty",
                message: errorText ?? "This folder has nothing in it."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(entries) { entry in
                        FileRow(
                            entry: entry,
                            isBusy: busyName == entry.name,
                            onOpen: { open(entry) },
                            onDownload: { download(entry) },
                            onDelete: {
                                pendingDelete = entry
                                showDeleteConfirm = true
                            },
                            onCopyPath: {
                                UIPasteboard.general.string = entry.path
                                banner = "Copied \(entry.path)"
                            }
                        )
                    }
                }
                .padding(.horizontal, Theme.pagePadding)
                .padding(.bottom, 16)
            }
        }
    }

    private var newFolderSheet: some View {
        NavigationView {
            Form {
                Section(header: Text("Folder name")) {
                    TextField("e.g. backups", text: $newFolderName)
                        .autocorrectionDisabled()
                        .autocapitalization(.none)
                }
                Section {
                    Text("Will be created in \(currentPath)")
                        .font(.footnote)
                        .foregroundColor(Theme.secondaryText)
                }
            }
            .navigationBarTitle("New folder", displayMode: .inline)
            .navigationBarItems(
                leading: Button("Cancel") { activeSheet = nil },
                trailing: Button("Create") {
                    activeSheet = nil
                    createFolder(newFolderName)
                }
                .disabled(newFolderName.trimmingCharacters(in: .whitespaces).isEmpty)
            )
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    // MARK: - 路径

    private var parentPath: String? {
        guard currentPath != "/" else { return nil }
        var trimmed = currentPath
        while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let index = trimmed.lastIndex(of: "/") else { return nil }
        return index == trimmed.startIndex ? "/" : String(trimmed[trimmed.startIndex..<index])
    }

    private func join(_ name: String) -> String {
        currentPath.hasSuffix("/") ? currentPath + name : currentPath + "/" + name
    }

    private func goUp() {
        guard let parent = parentPath else { return }
        currentPath = parent
        load()
    }

    private func open(_ entry: FileEntry) {
        if entry.isDirectory {
            currentPath = entry.path
            load()
        } else {
            download(entry)
        }
    }

    // MARK: - 取数

    private func load() {
        guard !isLoading else { return }
        isLoading = true
        errorText = nil
        banner = nil

        let path = currentPath
        Task {
            guard service.isReady else {
                await MainActor.run {
                    errorText = service.notReadyReason
                    isLoading = false
                }
                return
            }

            let result = await service.shell("ls -la \"\(path)\"")
            let parsed = FileEntry.parseListing(result.output, directory: path)
            let failureText = result.trimmed

            await MainActor.run {
                isLoading = false
                if parsed.isEmpty && !failureText.isEmpty && failureText.contains("No such file") {
                    errorText = failureText
                    entries = []
                } else {
                    entries = parsed
                }
            }
        }
    }

    // MARK: - 动作

    private func download(_ entry: FileEntry) {
        guard service.isReady else {
            errorText = service.notReadyReason
            return
        }
        busyName = entry.name
        errorText = nil
        banner = "Downloading \(entry.name)…"

        Task {
            let folder = service.documentsURL.appendingPathComponent("Downloads", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent(Self.safeFileName(entry.name))

            let result = await service.pull(remotePath: entry.path, localPath: destination.path)

            await MainActor.run {
                busyName = nil
                if result.ok && FileManager.default.fileExists(atPath: destination.path) {
                    banner = "Saved \(entry.name) — opening share sheet."
                    shareItems = [destination]
                    activeSheet = .share
                } else {
                    errorText = result.trimmed.isEmpty ? "Pull failed." : result.trimmed
                }
            }
        }
    }

    private func upload(_ url: URL) {
        guard service.isReady else {
            errorText = service.notReadyReason
            return
        }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let staging = service.documentsURL.appendingPathComponent("upload-staging", isDirectory: true)
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

        let remote = join(url.lastPathComponent)
        busyName = url.lastPathComponent
        errorText = nil
        banner = "Uploading \(url.lastPathComponent)…"

        Task {
            let result = await service.push(localPath: local.path, remotePath: remote)
            await MainActor.run {
                busyName = nil
                if result.ok {
                    banner = "Uploaded to \(remote)"
                    load()
                } else {
                    errorText = result.trimmed.isEmpty ? "Push failed." : result.trimmed
                }
            }
        }
    }

    private func createFolder(_ rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let target = join(name)

        busyName = name
        errorText = nil
        Task {
            let result = await service.shell("mkdir -p \"\(target)\" && echo OK")
            await MainActor.run {
                busyName = nil
                if result.trimmed.contains("OK") {
                    banner = "Created \(name)"
                    load()
                } else {
                    errorText = result.trimmed.isEmpty ? "mkdir failed." : result.trimmed
                }
            }
        }
    }

    private func delete(_ entry: FileEntry) {
        busyName = entry.name
        errorText = nil
        Task {
            let result = await service.shell("rm -rf \"\(entry.path)\" && echo OK")
            await MainActor.run {
                busyName = nil
                if result.trimmed.contains("OK") {
                    banner = "Deleted \(entry.name)"
                    entries.removeAll { $0.id == entry.id }
                } else {
                    errorText = result.trimmed.isEmpty ? "rm failed." : result.trimmed
                }
            }
        }
    }

    /// 拉回本地时用的文件名 —— 去掉路径分隔符，避免写到自己不想写的地方。
    private static func safeFileName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "_")
        return cleaned.isEmpty ? "download" : cleaned
    }
}

// MARK: - 文件条目

struct FileEntry: Identifiable {
    var id: String { path }
    let name: String
    let path: String
    let isDirectory: Bool
    let isLink: Bool
    let size: Int64
    let dateText: String

    /// 解析 `ls -la` 的输出。
    static func parseListing(_ output: String, directory: String = "") -> [FileEntry] {
        var result: [FileEntry] = []

        for rawLine in output.split(separator: "\n") {
            let line = String(rawLine)

            // `total 818` 之类的汇总行
            if line.hasPrefix("total ") { continue }
            // 错误行（`ls: /x: No such file or directory`）
            if line.hasPrefix("ls:") { continue }

            // ★ 按空白切成**至多 8 段**：前 7 段是字段，第 8 段是完整文件名（可含空格）。
            let parts = line.split(separator: " ", maxSplits: 7, omittingEmptySubsequences: true)
            guard parts.count >= 8 else { continue }

            let permissions = String(parts[0])
            let size = Int64(parts[4]) ?? 0
            let dateText = "\(parts[5]) \(parts[6])"
            var name = String(parts[7])

            // 符号链接：`name -> target`，只留名字
            if let arrow = name.range(of: " -> ") {
                name = String(name[name.startIndex..<arrow.lowerBound])
            }

            // 跳过 . 和 ..
            if name == "." || name == ".." || name.isEmpty { continue }

            let isDirectory = permissions.hasPrefix("d")
            let isLink = permissions.hasPrefix("l")

            result.append(FileEntry(
                name: name,
                path: directory.isEmpty ? name : Self.join(directory, name),
                isDirectory: isDirectory,
                isLink: isLink,
                size: size,
                dateText: dateText
            ))
        }

        return result.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private static func join(_ directory: String, _ name: String) -> String {
        if directory.hasSuffix("/") { return directory + name }
        return directory + "/" + name
    }

    var iconName: String {
        if isDirectory { return "folder.fill" }
        if isLink { return "link" }

        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "gif", "webp", "bmp", "heic": return "photo.fill"
        case "mp4", "mkv", "mov", "avi", "webm", "3gp": return "film.fill"
        case "mp3", "wav", "m4a", "flac", "ogg", "aac": return "music.note"
        case "apk", "apks", "xapk": return "shippingbox.fill"
        case "zip", "rar", "7z", "tar", "gz": return "doc.zipper"
        case "txt", "log", "json", "xml", "csv": return "doc.text.fill"
        case "pdf": return "doc.richtext.fill"
        default: return "doc.fill"
        }
    }

    var iconColor: Color {
        if isDirectory { return Theme.accent }
        if isLink { return Theme.warnForeground }
        switch iconName {
        case "photo.fill": return Color(hex: 0x34C77B)
        case "film.fill": return Color(hex: 0x9B51E0)
        case "music.note": return Color(hex: 0xF5A623)
        case "shippingbox.fill": return Color(hex: 0x3DDC84)
        case "doc.zipper": return Color(hex: 0xEB5757)
        default: return Theme.secondaryText
        }
    }

    var sizeText: String {
        isDirectory ? "—" : AdbToolService.formatBytes(size)
    }
}

// MARK: - 一行文件

private struct FileRow: View {
    let entry: FileEntry
    let isBusy: Bool
    let onOpen: () -> Void
    let onDownload: () -> Void
    let onDelete: () -> Void
    let onCopyPath: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(entry.iconColor.opacity(0.15))
                    Image(systemName: entry.iconName)
                        .font(.system(size: 17))
                        .foregroundColor(entry.iconColor)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.name)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Text("\(entry.sizeText)  ·  \(entry.dateText)")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.secondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if isBusy {
                    ProgressView()
                } else if entry.isDirectory {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.secondaryText)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .fill(Theme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .stroke(Theme.separator, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !entry.isDirectory {
                Button { onDownload() } label: { Label("Download", systemImage: "arrow.down.circle") }
            }
            Button { onCopyPath() } label: { Label("Copy path", systemImage: "doc.on.doc") }
            Divider()
            Button(role: .destructive) { onDelete() } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

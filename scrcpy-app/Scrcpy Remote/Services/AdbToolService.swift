//
//  AdbToolService.swift
//  Scrcpy Remote
//
//  Console 下所有工具页共用的 ADB 工具层。
//
//  它只做一件事：把 `ADBClient` 那套 ObjC 回调包装成 async/await。
//  真正的 adb 实现（libadb）在 `scrcpy-app/ADBClient/ScrcpyADBClient.m`，这里不碰它。
//
//  ★★ 三条硬约束（决定了下面每个函数长什么样）：
//
//  1. **没有流式 API**。底层是 `adb_commandline_porting` —— 一次一调、输出攒在 buffer 里、
//     跑完才返回。所以 `logcat` 必须带 `-d`（dump 后退出），
//     `screenrecord` 必须带 `--time-limit`。任何"永不返回"的命令都会把线程挂死。
//
//  2. **必须带 `-s <serial>`**。连上之后 adb 设备表里可能同时有隧道口、局域网直连、
//     甚至别的手机的条目，不带 `-s` 会挑错人（这个坑 Windows 端踩过：设备表脏了之后
//     scrcpy 推 server 直接报 `remote unknown command`）。
//
//  3. **阻塞式**。`executeADBCommand` 是同步阻塞调用，一律丢到后台队列跑，
//     绝不能在主线程上调（慢命令会把 UI 冻住）。
//

import Foundation

final class AdbToolService {

    static let shared = AdbToolService()
    private init() {}

    // MARK: - 结果

    struct RunResult {
        let output: String
        let code: Int32
        var ok: Bool { code == 0 }
        /// 去掉首尾空白后的输出。
        var trimmed: String {
            output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: - 当前设备

    /// 当前会话实际用的 ADB serial，形如 `192.168.1.5:5555` / `127.0.0.1:20000`。
    ///
    /// 取 `actualHost:actualPort` —— 这两个就是连接时真正 `adb connect` 的地址
    /// （`SessionConnectionManager.setCurrentSession` 里从 `NetworkConnectionInfo` 设进来的，
    /// 和 `ScrcpyADBClient.m` 拼 serial 用的是同一份数据）。
    /// 三条路都适用：局域网直连 / frp XTCP（127.0.0.1:visitorPort）/ Tailscale（127.0.0.1:转发端口）。
    var serial: String? {
        let manager = SessionConnectionManager.shared
        guard let host = manager.actualHost, let port = manager.actualPort,
              !host.isEmpty, !port.isEmpty else {
            return nil
        }
        return "\(host):\(port)"
    }

    /// 当前会话是不是 ADB 类型（VNC 会话没有 shell 可言）。
    var isADBSession: Bool {
        SessionConnectionManager.shared.currentSession?.deviceType == .adb
    }

    /// 工具页能不能干活：连着、是 ADB 会话、serial 拿得到。
    var isReady: Bool {
        isADBSession && serial != nil && ADBClient.shared().isADBLaunched
    }

    /// 拿不到 serial 时给用户看的理由。
    var notReadyReason: String {
        if !ADBClient.shared().isADBLaunched { return "ADB client is not ready yet." }
        if SessionConnectionManager.shared.currentSession == nil { return "No device connected." }
        if !isADBSession { return "This is a VNC session — the ADB tools need an Android device." }
        if serial == nil { return "Connection is not established yet." }
        return "Not ready."
    }

    // MARK: - 执行

    /// 跑一条 adb 命令（原始 argv 形式）。serial 传 nil 就用当前会话。
    func run(_ arguments: [String], serial explicitSerial: String? = nil) async -> RunResult {
        let client = ADBClient.shared()

        guard client.isADBLaunched else {
            return RunResult(output: "ADB client not launched", code: -1)
        }

        // 统一补 `-s <serial>`：调用方传的 argv 里要么没有 -s，要么自己带了。
        var argv = arguments
        if let target = explicitSerial ?? serial, !argv.contains("-s") {
            argv = ["-s", target] + argv
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var code: Int32 = -1
                let output = client.executeADBCommand(argv, returnCode: &code)
                continuation.resume(returning: RunResult(output: output, code: code))
            }
        }
    }

    /// 跑一条 shell 命令。
    func shell(_ command: String, serial explicitSerial: String? = nil) async -> RunResult {
        await run(["shell", command], serial: explicitSerial)
    }

    /// 跑一条 `adb <subcommand>`（不带 shell），例如 install / push / pull。
    func adb(_ arguments: [String], serial explicitSerial: String? = nil) async -> RunResult {
        await run(arguments, serial: explicitSerial)
    }

    // MARK: - 文件传输

    /// 本地沙盒里的工作目录（= ADB home，也就是 App 的 Documents）。
    var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    func push(localPath: String, remotePath: String, serial explicitSerial: String? = nil) async -> RunResult {
        await run(["push", localPath, remotePath], serial: explicitSerial)
    }

    func pull(remotePath: String, localPath: String, serial explicitSerial: String? = nil) async -> RunResult {
        await run(["pull", remotePath, localPath], serial: explicitSerial)
    }

    // MARK: - 输出解析小工具

    /// 按 `key=value` 行解析。
    static func parseKeyValues(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let range = line.range(of: ":") else { continue }
            let key = line[line.startIndex..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let value = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty && !value.isEmpty {
                result[key] = value
            }
        }
        return result
    }

    /// 人类可读的字节数。
    static func formatBytes(_ bytes: Int64) -> String {
        if bytes < 0 { return "—" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1024 && index < units.count - 1 {
            value /= 1024
            index += 1
        }
        return index == 0
            ? "\(Int(value)) \(units[index])"
            : String(format: "%.1f %@", value, units[index])
    }
}

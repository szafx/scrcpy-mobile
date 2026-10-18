//
//  ScriptRunner.swift
//  Scrcpy Remote
//
//  脚本执行引擎（2026-10-18）。
//
//  串行执行每个步骤，全部落到 adb shell：
//    · 坐标用归一化比例 → 按当前设备 wm size 换算成像素
//    · input text 只支持 ASCII（空格转 %s）
//    · 识图步骤：截屏 → 模板匹配 → 点命中位置（可只定位不点击）
//
//  ⚠️ `AdbToolService` 底层是同步阻塞、不可取消的；这里用 30s 软超时兜底，
//     Stop 只在步骤边界生效。
//

import Foundation
import UIKit

enum ScriptRunError: LocalizedError {
    case notConnected
    case noSteps
    case commandFailed(String)
    case timeout(String)
    case nonASCII
    case missingTemplate
    case screenshotFailed
    case imageNotFound

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "设备未连接，脚本需要走 adb 执行。"
        case .noSteps:
            return "脚本里没有启用的步骤。"
        case .commandFailed(let output):
            return "命令执行失败：\(output)"
        case .timeout(let cmd):
            return "命令超时（30s）：\(cmd)"
        case .nonASCII:
            return "输入文字目前只支持 ASCII（英文/数字/符号）。"
        case .missingTemplate:
            return "识图步骤缺少模板图片。"
        case .screenshotFailed:
            return "截屏失败（页面可能受 FLAG_SECURE 保护）。"
        case .imageNotFound:
            return "在超时时间内没有找到目标图片。"
        }
    }
}

@MainActor
final class ScriptRunner: ObservableObject {

    enum RunState: Equatable {
        case idle
        case running
        case finished
        case failed(String)
    }

    @Published private(set) var state: RunState = .idle
    @Published private(set) var isRunning = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var currentSummary: String = ""
    @Published private(set) var logs: [String] = []

    private var task: Task<Void, Never>?
    private var totalSteps = 0
    private var doneSteps = 0

    var errorText: String? {
        if case .failed(let message) = state { return message }
        return nil
    }

    // MARK: - 控制

    func start(script: RemoteScript) {
        guard !isRunning else { return }
        reset()
        isRunning = true
        state = .running

        task = Task { [weak self] in
            await self?.runScript(script)
        }
    }

    func stop() {
        task?.cancel()
        appendLog("⏹ 已请求停止（当前 adb 命令结束后停止）")
    }

    // MARK: - 主流程

    private func runScript(_ script: RemoteScript) async {
        defer {
            isRunning = false
            task = nil
        }

        guard AdbToolService.shared.isReady else {
            fail(ScriptRunError.notConnected)
            return
        }

        let enabledSteps = script.steps.filter { $0.enabled }
        guard !enabledSteps.isEmpty else {
            fail(ScriptRunError.noSteps)
            return
        }

        let size = await DeviceDisplaySizeStore.shared.currentSize()
            ?? CGSize(width: script.referenceWidth, height: script.referenceHeight)
        appendLog("📱 设备分辨率 \(Int(size.width))×\(Int(size.height))")

        let repeats = max(1, script.repeatCount)
        totalSteps = enabledSteps.count * repeats
        doneSteps = 0
        progress = 0

        appendLog("▶️ 开始执行「\(script.name.isEmpty ? "未命名脚本" : script.name)」，共 \(totalSteps) 步")

        for round in 1...repeats {
            if Task.isCancelled {
                appendLog("⏹ 已停止")
                state = .idle
                return
            }
            if repeats > 1 {
                appendLog("—— 第 \(round)/\(repeats) 轮 ——")
            }

            for step in enabledSteps {
                if Task.isCancelled {
                    appendLog("⏹ 已停止")
                    state = .idle
                    return
                }

                currentSummary = "第 \(doneSteps + 1)/\(totalSteps) 步 · \(step.summary)"
                appendLog("▸ \(step.summary)")

                do {
                    try await execute(step, size: size, script: script)
                } catch is CancellationError {
                    appendLog("⏹ 已停止")
                    state = .idle
                    return
                } catch {
                    fail(error)
                    return
                }

                doneSteps += 1
                progress = Double(doneSteps) / Double(totalSteps)
            }
        }

        currentSummary = "已完成"
        appendLog("✅ 脚本执行完成")
        state = .finished
    }

    // MARK: - 单步执行

    private func execute(_ step: ScriptStep, size: CGSize, script: RemoteScript) async throws {
        switch step.type {
        case .tap:
            try await runShell("input tap \(pixel(step.x1, size.width)) \(pixel(step.y1, size.height))")

        case .longPress:
            let x = pixel(step.x1, size.width)
            let y = pixel(step.y1, size.height)
            let duration = max(100, step.durationMs)
            try await runShell("input swipe \(x) \(y) \(x) \(y) \(duration)")

        case .swipe:
            let x1 = pixel(step.x1, size.width)
            let y1 = pixel(step.y1, size.height)
            let x2 = pixel(step.x2, size.width)
            let y2 = pixel(step.y2, size.height)
            let duration = max(50, step.durationMs)
            try await runShell("input swipe \(x1) \(y1) \(x2) \(y2) \(duration)")

        case .key:
            try await runShell("input keyevent \(step.keyCode)")

        case .text:
            let quoted = try shellQuotedText(step.text)
            try await runShell("input text \(quoted)")

        case .wait:
            let ms = max(0, step.waitMs)
            appendLog("   等待 \(ms)ms")
            try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            if Task.isCancelled { throw CancellationError() }

        case .shell:
            let command = step.shell.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else { throw ScriptRunError.commandFailed("Shell 步骤为空") }
            try await runShell(command)

        case .imageTap:
            try await performImageTap(step, script: script)
        }
    }

    private func runShell(_ command: String) async throws {
        appendLog("   $ \(command)")

        let result = await withTimeout(seconds: 30) {
            await AdbToolService.shared.shell(command)
        }

        guard let result else {
            throw ScriptRunError.timeout(command)
        }
        if !result.trimmed.isEmpty {
            appendLog("   " + String(result.trimmed.prefix(300)))
        }
        guard result.code == 0 else {
            throw ScriptRunError.commandFailed(result.trimmed.isEmpty ? "exit \(result.code)" : result.trimmed)
        }
    }

    // MARK: - 识图点击

    private func performImageTap(_ step: ScriptStep, script: RemoteScript) async throws {
        guard let file = step.templateFile,
              let template = ScriptManager.shared.templateImage(named: file) else {
            throw ScriptRunError.missingTemplate
        }

        let timeout = max(500, step.matchTimeoutMs)
        let deadline = Date().addingTimeInterval(Double(timeout) / 1000.0)
        var lastScore: Double = 0

        while Date() < deadline {
            if Task.isCancelled { throw CancellationError() }

            guard let screen = await ScreenshotService.capture() else {
                throw ScriptRunError.screenshotFailed
            }

            if let match = TemplateMatcher.find(
                template: template,
                in: screen,
                referenceWidth: CGFloat(step.templateRefWidth > 0 ? step.templateRefWidth : script.referenceWidth),
                threshold: step.threshold) {

                let tapX = Int((match.center.x * screen.size.width).rounded())
                let tapY = Int((match.center.y * screen.size.height).rounded())
                appendLog(String(format: "   识图命中 score=%.3f 归一化(%.3f, %.3f) → (%d, %d)",
                                 match.score, match.center.x, match.center.y, tapX, tapY))

                if step.dryRun {
                    appendLog("   （仅定位模式，不点击）")
                    return
                }
                try await runShell("input tap \(tapX) \(tapY)")
                return
            }

            if let score = TemplateMatcher.lastBestScore {
                lastScore = score
            }
            appendLog(String(format: "   未命中（当前最高 %.3f），%.0fms 后重试",
                             lastScore, 700))
            try await Task.sleep(nanoseconds: 700 * 1_000_000)
        }

        throw ScriptRunError.imageNotFound
    }

    // MARK: - 工具

    private func pixel(_ ratio: Double, _ dimension: CGFloat) -> Int {
        let value = ratio * Double(dimension)
        return max(0, min(Int(dimension) - 1, Int(value.rounded())))
    }

    /// adb `input text` 的转义：空格必须写 %s；整个参数用单引号包住。
    private func shellQuotedText(_ text: String) throws -> String {
        guard !text.isEmpty else { throw ScriptRunError.commandFailed("输入文字为空") }
        guard text.unicodeScalars.allSatisfy({ $0.isASCII }) else {
            throw ScriptRunError.nonASCII
        }
        let spaced = text.replacingOccurrences(of: " ", with: "%s")
        let escaped = spaced.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    private func withTimeout<T>(seconds: TimeInterval,
                                operation: @escaping () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func reset() {
        state = .idle
        progress = 0
        currentSummary = ""
        logs = []
        totalSteps = 0
        doneSteps = 0
        TemplateMatcher.lastBestScore = nil
    }

    private func appendLog(_ line: String) {
        logs.append(line)
        if logs.count > 300 {
            logs.removeFirst(logs.count - 300)
        }
    }

    private func fail(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        appendLog("❌ " + message)
        state = .failed(message)
    }
}

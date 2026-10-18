//
//  ScriptModels.swift
//  Scrcpy Remote
//
//  远端安卓「脚本」的数据模型（2026-10-18）。
//
//  设计要点：
//    · 用户在 UI 里定制步骤，执行时全部翻译成 adb shell 命令
//      （input tap/swipe/keyevent/text、任意 shell）。
//    · **坐标一律存归一化比例 0…1** —— 8 台手机分辨率不同，运行时按当前设备
//      实际分辨率换算；换机器不用重画。
//    · 识图点击（imageTap）不用坐标：截屏 → 模板匹配 → 点命中位置。
//

import Foundation

// MARK: - 步骤类型

enum ScriptStepType: String, Codable, CaseIterable, Identifiable {
    case tap
    case longPress
    case swipe
    case key
    case text
    case wait
    case shell
    case imageTap

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tap:       return "点击"
        case .longPress: return "长按"
        case .swipe:     return "滑动"
        case .key:       return "按键"
        case .text:      return "输入文字"
        case .wait:      return "等待"
        case .shell:     return "Shell 命令"
        case .imageTap:  return "识图点击"
        }
    }

    var systemImage: String {
        switch self {
        case .tap:       return "hand.tap"
        case .longPress: return "hand.point.up.left"
        case .swipe:     return "hand.draw"
        case .key:       return "keyboard"
        case .text:      return "text.cursor"
        case .wait:      return "clock"
        case .shell:     return "terminal"
        case .imageTap:  return "viewfinder.circle"
        }
    }

    /// 新增该类型步骤时的默认参数
    var defaultStep: ScriptStep {
        var step = ScriptStep(type: self)
        switch self {
        case .tap:
            step.x1 = 0.5; step.y1 = 0.5
        case .longPress:
            step.x1 = 0.5; step.y1 = 0.5; step.durationMs = 600
        case .swipe:
            step.x1 = 0.5; step.y1 = 0.7; step.x2 = 0.5; step.y2 = 0.3; step.durationMs = 300
        case .key:
            step.keyCode = 4
        case .text:
            step.text = ""
        case .wait:
            step.waitMs = 1000
        case .shell:
            step.shell = ""
        case .imageTap:
            step.threshold = 0.88
            step.matchTimeoutMs = 5000
        }
        return step
    }
}

// MARK: - 步骤

struct ScriptStep: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var type: ScriptStepType = .tap
    var enabled: Bool = true

    /// 归一化坐标（0…1，相对设备宽高）
    var x1: Double = 0.5
    var y1: Double = 0.5
    var x2: Double = 0.5
    var y2: Double = 0.5

    /// swipe / longPress 时长（毫秒）
    var durationMs: Int = 300

    /// 安卓原始键码（AKEYCODE_*）
    var keyCode: Int = 4

    /// input text 的文本（仅 ASCII）
    var text: String = ""

    /// 等待时长（毫秒）
    var waitMs: Int = 1000

    /// 任意 adb shell 命令（原文，不再拆词）
    var shell: String = ""

    /// 识图：模板文件名（Documents/ScriptTemplates/ 下）
    var templateFile: String? = nil
    /// 识图：模板裁剪时那张截图的宽度（用于运行时换算尺度；0 = 用脚本参考宽度）
    var templateRefWidth: Int = 0
    /// 识图：匹配阈值 0…1
    var threshold: Double = 0.88
    /// 识图：等待目标出现的超时（毫秒）
    var matchTimeoutMs: Int = 5000
    /// 识图：只定位不点击（调试用）
    var dryRun: Bool = false

    init(type: ScriptStepType) {
        self.type = type
    }

    /// 列表里展示的一行摘要
    var summary: String {
        switch type {
        case .tap:
            return String(format: "点击 (%.1f%%, %.1f%%)", x1 * 100, y1 * 100)
        case .longPress:
            return String(format: "长按 (%.1f%%, %.1f%%) %.0fms", x1 * 100, y1 * 100, Double(durationMs))
        case .swipe:
            return String(format: "滑动 (%.1f%%, %.1f%%) → (%.1f%%, %.1f%%) %.0fms",
                          x1 * 100, y1 * 100, x2 * 100, y2 * 100, Double(durationMs))
        case .key:
            return "按键 " + (ScriptKeyCatalog.name(for: keyCode) ?? "\(keyCode)")
        case .text:
            return "输入 “\(text)”"
        case .wait:
            return String(format: "等待 %.2fs", Double(waitMs) / 1000.0)
        case .shell:
            return "Shell: " + (shell.isEmpty ? "（未填写）" : shell)
        case .imageTap:
            let name = templateFile.map { ($0 as NSString).lastPathComponent } ?? "（未选模板）"
            return String(format: "识图点击 %@（阈值 %.2f%@）", name, threshold, dryRun ? "，仅定位" : "")
        }
    }
}

// MARK: - 脚本

struct RemoteScript: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String = ""

    /// nil = 通用（所有设备可用）；有值 = 绑定某台设备的会话 id
    var deviceId: UUID? = nil

    /// 创建脚本时的设备分辨率 —— 仅用于编辑器里把比例显示成像素
    var referenceWidth: Int = 1080
    var referenceHeight: Int = 2400

    /// 整脚本重复次数
    var repeatCount: Int = 1

    var steps: [ScriptStep] = []
    var updatedAt: Date = Date()

    /// 归一化 → 像素
    func pixel(_ ratio: Double, of dimension: Int) -> Int {
        max(0, min(dimension - 1, Int((ratio * Double(dimension)).rounded())))
    }
}

// MARK: - 常用安卓键码

struct ScriptKeyOption: Identifiable, Hashable {
    let id: Int          // keycode
    let name: String
}

enum ScriptKeyCatalog {
    static let options: [ScriptKeyOption] = [
        ScriptKeyOption(id: 4,   name: "返回 BACK"),
        ScriptKeyOption(id: 3,   name: "主页 HOME"),
        ScriptKeyOption(id: 187, name: "最近任务 APP_SWITCH"),
        ScriptKeyOption(id: 82,  name: "菜单 MENU"),
        ScriptKeyOption(id: 66,  name: "回车 ENTER"),
        ScriptKeyOption(id: 67,  name: "退格 DEL"),
        ScriptKeyOption(id: 61,  name: "TAB"),
        ScriptKeyOption(id: 111, name: "ESC"),
        ScriptKeyOption(id: 19,  name: "方向上"),
        ScriptKeyOption(id: 20,  name: "方向下"),
        ScriptKeyOption(id: 21,  name: "方向左"),
        ScriptKeyOption(id: 22,  name: "方向右"),
        ScriptKeyOption(id: 23,  name: "确定 CENTER"),
        ScriptKeyOption(id: 24,  name: "音量 +"),
        ScriptKeyOption(id: 25,  name: "音量 −"),
        ScriptKeyOption(id: 26,  name: "电源键"),
    ]

    static func name(for code: Int) -> String? {
        options.first { $0.id == code }?.name
    }
}

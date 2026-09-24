//
//  Theme.swift
//  Scrcpy Remote
//
//  VRLink 那套视觉的设计令牌。
//
//  数值来源：`Desktop/iOS-sideload/VRLink-拆解-UI与功能模块.md` 第二节（从 7 张官方截图量取）。
//  这里只放「值」，不放控件 —— 控件在 Components.swift。
//
//  ★ 全部用 iOS 15/16 安全 API。目标机是 iOS 16.2（越狱的 iPhone 14 PM），
//    工程最低版本 15.0，不要用 @Observable / iOS 17 的写法。
//

import SwiftUI
import UIKit

enum Theme {

    // MARK: - 颜色

    /// 主色 = iOS systemBlue。VRLink 亮色 #007AFF、暗色 #0A84FF。
    static let accent = Color.adaptive(light: 0x007AFF, dark: 0x0A84FF)

    /// 页面底色：亮色系统灰 #F2F2F7，暗色纯黑。
    static let background = Color.adaptive(light: 0xF2F2F7, dark: 0x000000)

    /// 卡片底色：亮色纯白，暗色 #1C1C1E。
    static let card = Color.adaptive(light: 0xFFFFFF, dark: 0x1C1C1E)

    /// 卡片内分隔/描边（极淡）。
    static let separator = Color.adaptive(light: 0xE5E5EA, dark: 0x2C2C2E)

    /// 次级文字（副标题那两行灰字）。
    static let secondaryText = Color.adaptive(light: 0x8E8E93, dark: 0x8E8E93)

    /// Hero 卡渐变（蓝 → 紫）。
    static let heroGradient = LinearGradient(
        gradient: Gradient(colors: [Color(hex: 0x3B7DFF), Color(hex: 0x8B5CF6)]),
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// 状态：已连接（绿底浅绿字）。
    static let okBackground = Color.adaptive(light: 0xE3F9E5, dark: 0x14351C)
    static let okForeground = Color.adaptive(light: 0x1E8E3E, dark: 0x4ADE80)

    /// 状态：空闲 / 未连接（灰底）。
    static let idleBackground = Color.adaptive(light: 0xEFEFF4, dark: 0x2C2C2E)
    static let idleForeground = Color.adaptive(light: 0x8E8E93, dark: 0x98989F)

    /// 状态：警告（橙）。
    static let warnForeground = Color.adaptive(light: 0xE8710A, dark: 0xFFB020)

    /// 状态：危险（红，卸载/删除）。
    static let dangerForeground = Color.adaptive(light: 0xFF3B30, dark: 0xFF453A)

    // MARK: - 圆角

    /// 卡片圆角。VRLink 量出来是 16–20pt。
    static let cardRadius: CGFloat = 18
    /// Hero 卡 / 工具大块圆角。
    static let heroRadius: CGFloat = 20
    /// 「圆角方块」工具图标（squircle）圆角。
    static let iconRadius: CGFloat = 12
    /// 药丸 / 芯片（全圆角）。
    static let pillRadius: CGFloat = 100

    // MARK: - 间距

    static let pagePadding: CGFloat = 16
    static let cardPadding: CGFloat = 16
    static let gridSpacing: CGFloat = 12

    // MARK: - 尺寸

    /// 工具图标（Console 网格里的圆角方块）。
    static let toolIconSize: CGFloat = 52
    /// 右下浮动胶囊 TabBar 的高度。
    static let tabBarHeight: CGFloat = 62
    /// 圆形按钮（右上角 + / ↻ / ↓）。
    static let circleButtonSize: CGFloat = 38

    // MARK: - 工具图标配色
    //
    // VRLink 每个工具一个高饱和纯色底。按工具名固定取色，别用随机 ——
    // 每次进 Console 颜色不一样会显得很廉价。

    private static let toolPalette: [UInt32] = [
        0x4A90E2,   // 蓝   Device info
        0xF5A623,   // 橙   Apps
        0x34C77B,   // 绿   Files
        0x9B51E0,   // 紫   Screen mirror
        0x2D9CDB,   // 浅蓝 Screen snapshot
        0x56CCB0,   // 青   Quick input
        0x4A5568,   // 深灰 ADB shell
        0xEB5757,   // 红   Logs
        0x7B61FF,   // 靛   Actions
    ]

    /// 按工具在列表里的下标取色（固定、可复现）。
    static func toolColor(index: Int) -> Color {
        Color(hex: toolPalette[((index % toolPalette.count) + toolPalette.count) % toolPalette.count])
    }
}

// MARK: - 颜色工具

extension Color {

    /// `Color(hex: 0x007AFF)`
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: 1.0
        )
    }

    /// 亮/暗两套值。`AppSettings.applyTheme()` 是通过 `overrideUserInterfaceStyle`
    /// 切换的，`UIColor { traits in ... }` 会跟着走，两者不冲突。
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}

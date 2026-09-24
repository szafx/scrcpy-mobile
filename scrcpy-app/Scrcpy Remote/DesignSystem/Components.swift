//
//  Components.swift
//  Scrcpy Remote
//
//  VRLink 视觉语言里的基础控件。全是纯 SwiftUI、无依赖、iOS 15 安全。
//
//  对应截图里的：Hero 蓝紫渐变卡、圆角方块工具图标、状态药丸、筛选芯片、
//  右上角白色圆形按钮、空状态。
//

import SwiftUI
import UIKit

// MARK: - 分享面板

/// 把刚从手机拉下来的文件交给系统分享（存到「文件」/ 相册 / AirDrop 都行）。
///
/// 为什么要它：App 的 Info.plist 里没有开 `UIFileSharingEnabled`，
/// 所以 Documents 目录在「文件」App 里看不见 —— 拉下来的东西得手动送出去一次。
/// 顺带一个好处：adb 私钥也在 Documents 下，不开那个开关就不会被露出去。
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - 卡片容器

/// 通用白底圆角卡。
struct CardContainer<Content: View>: View {
    var padding: CGFloat = Theme.cardPadding
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
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

// MARK: - Hero 卡

/// Devices 页顶部那张蓝→紫渐变实心卡：左侧圆形图标 + 主标题 + 两行小字。
struct HeroCard: View {
    let icon: String
    // ★ 文字用 LocalizedStringKey：`Text(String变量)` 走 StringProtocol 重载、不查表，
    //   永远显示英文。写成 key 才会去 Localizable.strings 里找。
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.22))
                    .frame(width: 44, height: 44)
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.white)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.heroRadius, style: .continuous)
                .fill(Theme.heroGradient)
        )
    }
}

// MARK: - 状态药丸

enum StatusPillKind {
    case connected
    case idle
    case warning
    case danger
}

/// `Connected` 绿底浅绿字 / `Idle` 灰底。
struct StatusPill: View {
    let text: LocalizedStringKey
    var kind: StatusPillKind = .idle
    /// 前面那个小圆点（VRLink 的 Connected 药丸里有一个）。
    var showDot: Bool = true

    private var background: Color {
        switch kind {
        case .connected: return Theme.okBackground
        case .idle:      return Theme.idleBackground
        case .warning:   return Theme.warnForeground.opacity(0.14)
        case .danger:    return Theme.dangerForeground.opacity(0.13)
        }
    }

    private var foreground: Color {
        switch kind {
        case .connected: return Theme.okForeground
        case .idle:      return Theme.idleForeground
        case .warning:   return Theme.warnForeground
        case .danger:    return Theme.dangerForeground
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            if showDot {
                Circle()
                    .fill(foreground)
                    .frame(width: 6, height: 6)
            }
            Text(text)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundColor(foreground)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous).fill(background)
        )
    }
}

// MARK: - 筛选芯片

/// 小胶囊：选中 = 蓝底白字，未选 = 白底灰字。
struct FilterChip: View {
    let title: LocalizedStringKey
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(isSelected ? .white : Theme.secondaryText)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    Capsule(style: .continuous)
                        .fill(isSelected ? Theme.accent : Theme.card)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 圆形按钮

/// 右上角那个白圆 + 彩色字形（＋ / ↻ / ↓ / ⬅）。
struct CircleIconButton: View {
    let icon: String
    var tint: Color = Theme.accent
    var size: CGFloat = Theme.circleButtonSize
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Theme.card)
                    .shadow(color: Color.black.opacity(0.08), radius: 4, x: 0, y: 2)
                Image(systemName: icon)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundColor(tint)
            }
            .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 工具图标

/// 高饱和纯色圆角方块 + 白色 SF Symbol —— VRLink「设置」图标那套语言，但换成圆角矩形。
struct ToolIcon: View {
    let systemName: String
    let color: Color
    var size: CGFloat = Theme.toolIconSize

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(color)
            Image(systemName: systemName)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundColor(.white)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 空状态

/// 居中圆角方块浅色图标 + 粗体标题 + 灰色说明 + 可选主按钮。
struct EmptyStateView<Action: View>: View {
    let icon: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    @ViewBuilder var action: () -> Action

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Theme.idleBackground)
                    .frame(width: 84, height: 84)
                Image(systemName: icon)
                    .font(.system(size: 34, weight: .regular))
                    .foregroundColor(Theme.secondaryText)
            }

            Text(title)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.primary)

            Text(message)
                .font(.system(size: 14))
                .foregroundColor(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)

            action()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}

extension EmptyStateView where Action == EmptyView {
    init(icon: String, title: LocalizedStringKey, message: LocalizedStringKey) {
        self.init(icon: icon, title: title, message: message) { EmptyView() }
    }
}

// MARK: - 主按钮

/// 全宽蓝色主按钮（空状态里的 `Scan LAN`）。
struct PrimaryButton: View {
    let title: LocalizedStringKey
    var icon: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Theme.accent)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 快捷入口（图标 + 标签，横排）

/// Devices 页 Hero 卡下面那三个：Pair with code / Scan LAN / Manual。
///
/// 拆成「外观」和「按钮」两个，是因为其中一个（Pair with code）要用
/// `NavigationLink` 推页面，另外两个要触发 action。
struct QuickEntryLabel: View {
    let icon: String
    let title: LocalizedStringKey

    var body: some View {
        VStack(spacing: 8) {
            ToolIcon(systemName: icon, color: Theme.accent, size: 46)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

struct QuickEntryButton: View {
    let icon: String
    let title: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            QuickEntryLabel(icon: icon, title: title)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 页面标题

//
//  FloatingTabBar.swift
//  Scrcpy Remote
//
//  底部浮动毛玻璃胶囊 TabBar（VRLink 的 Devices / Console / Settings）。
//
//  为什么不用 SwiftUI 的 `TabView`：系统 TabBar 是贴底整条的，做不出
//  「悬浮胶囊 + 选中项一个灰胶囊底」这个观感。自己画反而更简单。
//

import SwiftUI

struct ShellTab: Identifiable, Equatable {
    let id: Int
    let icon: String
    let title: String
}

struct FloatingTabBar: View {
    @Binding var selected: Int
    let tabs: [ShellTab]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                item(tab)
            }
        }
        .padding(5)
        .background(
            Capsule(style: .continuous)
                .fill(Material.ultraThinMaterial)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 12, x: 0, y: 4)
    }

    @ViewBuilder
    private func item(_ tab: ShellTab) -> some View {
        let isSelected = selected == tab.id

        Button {
            if !isSelected {
                withAnimation(.easeInOut(duration: 0.18)) { selected = tab.id }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: tab.icon)
                    .font(.system(size: 15, weight: .semibold))
                Text(tab.title)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundColor(isSelected ? Theme.accent : Color.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                Capsule(style: .continuous)
                    .fill(isSelected ? Theme.idleBackground : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
    }
}

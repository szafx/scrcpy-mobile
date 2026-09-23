//
//  LatencyBadgeView.swift
//  Scrcpy Remote
//
//  连接成功后常驻在画面上的小气泡：一眼看到「现在走的是哪条路」和「延迟多少」。
//
//  为什么要有它：
//    局域网 / frp P2P / frp 中转 / Tailscale 这几条路的手感差很多（8ms vs 150ms），
//    但界面上原来完全看不出来走的是哪条 —— 出问题时要靠翻日志才知道。
//    常驻一个小条，卡不卡、走的哪条路，扫一眼就有数。
//
//  点一下可以展开，看到抖动和目标地址。
//

import Foundation
import SwiftUI

struct LatencyBadgeView: View {

    @ObservedObject private var monitor = LatencyMonitor.shared
    @ObservedObject private var manager = SessionConnectionManager.shared

    /// 展开态显示抖动 + 实际地址；默认收起，只占一行
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                // 圆点按延迟分档上色，瞟一眼就知道好不好
                Circle()
                    .fill(latencyColor)
                    .frame(width: 7, height: 7)

                Text(monitor.kind.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.primary)

                Text(latencyText)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundColor(latencyColor)
            }

            if expanded {
                if let jitter = monitor.jitterMs {
                    Text(String(format: "抖动 ±%.0f ms", jitter))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundColor(.secondary)
                }
                if let host = manager.actualHost, let port = manager.actualPort {
                    Text("\(host):\(port)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
        }
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }

    private var latencyText: String {
        guard let ms = monitor.latencyMs else { return "—" }
        return String(format: "%.0f ms", ms)
    }

    /// 延迟分档：跟实际手感对齐，别用 ping 那套阈值（那条路上 ICMP 会虚高）
    private var latencyColor: Color {
        guard let ms = monitor.latencyMs else { return .gray }
        if ms < 40 { return Color(red: 0.30, green: 0.85, blue: 0.45) }   // 跟手
        if ms < 90 { return Color(red: 0.95, green: 0.78, blue: 0.30) }   // 可用
        if ms < 160 { return Color(red: 0.98, green: 0.55, blue: 0.25) }  // 有点顿
        return Color(red: 0.95, green: 0.35, blue: 0.35)                  // 明显卡
    }
}

// 用老式 PreviewProvider —— 工程 target 是 iOS 15，#Preview 宏要求 iOS 17
struct LatencyBadgeView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            LatencyBadgeView()
        }
    }
}

//
//  ScriptRunView.swift
//  Scrcpy Remote
//
//  脚本运行页：运行前确认 → 进度 / 日志 / 停止（2026-10-18）。
//

import SwiftUI

struct ScriptRunView: View {

    let script: RemoteScript

    @StateObject private var runner = ScriptRunner()
    @Environment(\.dismiss) private var dismiss

    @State private var started = false
    @State private var currentSize: CGSize?

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                if started {
                    runningView
                } else {
                    confirmView
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .navigationTitle(script.name.isEmpty ? "运行脚本" : script.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") {
                        runner.stop()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if started && runner.isRunning {
                        Button(role: .destructive) {
                            runner.stop()
                        } label: {
                            Label("停止", systemImage: "stop.fill")
                        }
                    }
                }
            }
        }
        .task {
            currentSize = await DeviceDisplaySizeStore.shared.currentSize()
        }
        .onDisappear {
            runner.stop()
        }
    }

    // MARK: - 运行前确认

    private var confirmView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("即将在「\(deviceName)」上运行")
                .font(.system(size: 17, weight: .semibold))

            VStack(alignment: .leading, spacing: 6) {
                infoRow("步骤", "\(enabledSteps) 步")
                infoRow("重复", "\(max(1, script.repeatCount)) 次")
                infoRow("脚本参考分辨率", "\(script.referenceWidth)×\(script.referenceHeight)")
                if let size = currentSize {
                    infoRow("当前设备分辨率", "\(Int(size.width))×\(Int(size.height))")
                }
                if imageSteps > 0 {
                    infoRow("识图步骤", "\(imageSteps) 个，阈值依赖模板稳定性")
                }
            }
            .font(.system(size: 13))
            .foregroundColor(Theme.secondaryText)

            if imageSteps > 0 {
                Text("识图点击会截屏做模板匹配，找不到目标会等到超时后停止；误点风险由阈值控制。可以先在步骤里打开「仅定位不点击」测试。")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.secondaryText)
            }

            Button {
                runner.start(script: script)
                started = true
            } label: {
                HStack {
                    Image(systemName: "play.fill")
                    Text("开始运行")
                }
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.accent))
                .foregroundColor(.white)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 运行中

    private var runningView: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProgressView(value: runner.progress)
                .tint(Theme.accent)

            Text(runner.currentSummary.isEmpty ? "准备中…" : runner.currentSummary)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)

            if case .failed(let message) = runner.state {
                Text("❌ " + message)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.dangerForeground)
            } else if runner.state == .finished {
                Text("✅ 执行完成")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.green)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(runner.logs.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(index == runner.logs.count - 1 ? .primary : Theme.secondaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                }
                .frame(maxHeight: .infinity)
                .onChange(of: runner.logs.count) { _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
        }
    }

    // MARK: - 工具

    private var deviceName: String {
        SessionConnectionManager.shared.currentSession?.sessionName.isEmpty == false
            ? (SessionConnectionManager.shared.currentSession?.sessionName ?? "当前设备")
            : "当前设备"
    }

    private var enabledSteps: Int {
        script.steps.filter { $0.enabled }.count
    }

    private var imageSteps: Int {
        script.steps.filter { $0.enabled && $0.type == .imageTap }.count
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
        }
    }
}

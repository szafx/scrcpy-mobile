//
//  ScriptEditorView.swift
//  Scrcpy Remote
//
//  脚本编辑器：名称/重复次数 + 步骤列表（2026-10-18）。
//

import SwiftUI

struct ScriptEditorView: View {

    @State private var script: RemoteScript
    private let isNew: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var showAddStep = false
    @State private var currentSize: CGSize?

    init(script: RemoteScript, isNew: Bool = false) {
        _script = State(initialValue: script)
        self.isNew = isNew
    }

    var body: some View {
        Form {
            Section {
                TextField("脚本名称", text: $script.name)
                Stepper(value: $script.repeatCount, in: 1...999) {
                    HStack {
                        Text("重复次数")
                        Spacer()
                        Text("\(script.repeatCount)")
                            .foregroundColor(Theme.secondaryText)
                    }
                }
                HStack {
                    Text("参考分辨率")
                    Spacer()
                    Text("\(script.referenceWidth)×\(script.referenceHeight)")
                        .foregroundColor(Theme.secondaryText)
                }
                if let size = currentSize {
                    HStack {
                        Text("当前设备")
                        Spacer()
                        Text("\(Int(size.width))×\(Int(size.height))")
                            .foregroundColor(Theme.secondaryText)
                    }
                }
            } header: {
                Text("脚本")
            } footer: {
                Text("坐标保存为百分比，换不同分辨率的手机也能按比例点到同一位置。")
            }

            Section {
                ForEach($script.steps) { $step in
                    NavigationLink(destination: ScriptStepEditorView(step: $step)) {
                        ScriptStepRow(step: step)
                    }
                }
                .onDelete { offsets in
                    script.steps.remove(atOffsets: offsets)
                }
                .onMove { from, to in
                    script.steps.move(fromOffsets: from, toOffset: to)
                }

                Button {
                    showAddStep = true
                } label: {
                    Label("添加步骤", systemImage: "plus.circle.fill")
                }
            } header: {
                Text("步骤（\(script.steps.count)）")
            } footer: {
                Text("按顺序执行；每个步骤都会翻译成 adb shell 命令（input tap/swipe/keyevent/text 等）。")
            }
        }
        .navigationTitle(isNew ? "新建脚本" : "编辑脚本")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("保存") { save() }
            }
            ToolbarItem(placement: .navigationBarLeading) {
                if !script.steps.isEmpty {
                    EditButton()
                }
            }
        }
        .sheet(isPresented: $showAddStep) {
            ScriptAddStepSheet { type in
                script.steps.append(type.defaultStep)
            }
        }
        .task {
            guard let size = await DeviceDisplaySizeStore.shared.currentSize() else { return }
            currentSize = size
            if isNew {
                script.referenceWidth = Int(size.width)
                script.referenceHeight = Int(size.height)
            }
        }
    }

    private func save() {
        var toSave = script
        if toSave.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            toSave.name = "未命名脚本"
        }
        _ = ScriptManager.shared.save(toSave)
        dismiss()
    }
}

// MARK: - 步骤行

private struct ScriptStepRow: View {
    let step: ScriptStep

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: step.type.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(step.enabled ? Theme.accent : Theme.secondaryText)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(step.type.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(step.enabled ? Color.primary : Theme.secondaryText)
                Text(step.summary)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.secondaryText)
                    .lineLimit(2)
            }
        }
        .opacity(step.enabled ? 1 : 0.55)
    }
}

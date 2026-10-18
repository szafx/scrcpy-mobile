//
//  ScriptsListView.swift
//  Scrcpy Remote
//
//  Console → Scripts：脚本列表（2026-10-18）。
//

import SwiftUI

struct ScriptsListView: View {

    @ObservedObject private var manager = ScriptManager.shared
    @State private var newScript: RemoteScript?
    @State private var runTarget: RemoteScript?

    var body: some View {
        List {
            if manager.scripts.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("还没有脚本")
                            .font(.headline)
                        Text("点右上角 + 新建。脚本用 adb 执行，需要先连接设备。")
                            .font(.footnote)
                            .foregroundColor(Theme.secondaryText)
                    }
                    .padding(.vertical, 6)
                }
            }

            ForEach(manager.scripts) { script in
                NavigationLink(destination: ScriptEditorView(script: script)) {
                    row(script)
                }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    Button {
                        runTarget = script
                    } label: {
                        Label("运行", systemImage: "play.fill")
                    }
                    .tint(.green)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        manager.delete(id: script.id)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                    Button {
                        _ = manager.duplicate(script)
                    } label: {
                        Label("复制", systemImage: "plus.square.on.square")
                    }
                    .tint(.blue)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Scripts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    var script = RemoteScript()
                    script.name = "新脚本"
                    newScript = script
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(item: $newScript) { script in
            NavigationView {
                ScriptEditorView(script: script, isNew: true)
            }
        }
        .sheet(item: $runTarget) { script in
            ScriptRunView(script: script)
        }
    }

    private func row(_ script: RemoteScript) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "scroll")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Theme.accent)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(script.name.isEmpty ? "未命名脚本" : script.name)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text("\(script.steps.count) 步" +
                     (script.repeatCount > 1 ? " · 重复 \(script.repeatCount) 次" : ""))
                    .font(.system(size: 12))
                    .foregroundColor(Theme.secondaryText)
            }

            Spacer(minLength: 6)

            Button {
                runTarget = script
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.green)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }
}

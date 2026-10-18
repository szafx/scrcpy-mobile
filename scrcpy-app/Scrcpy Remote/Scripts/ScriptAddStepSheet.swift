//
//  ScriptAddStepSheet.swift
//  Scrcpy Remote
//
//  添加步骤：选择步骤类型（2026-10-18）。
//

import SwiftUI

struct ScriptAddStepSheet: View {

    @Environment(\.dismiss) private var dismiss
    var onSelect: (ScriptStepType) -> Void

    var body: some View {
        NavigationView {
            List(ScriptStepType.allCases) { type in
                Button {
                    onSelect(type)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: type.systemImage)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(Theme.accent)
                            .frame(width: 28)
                        Text(type.title)
                            .foregroundColor(.primary)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("添加步骤")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}

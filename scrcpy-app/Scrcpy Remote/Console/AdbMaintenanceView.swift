//
//  AdbMaintenanceView.swift
//  Scrcpy Remote
//
//  ADB 维护（2026-10-19）：
//  部分机型（vivo/OriginOS、部分 MIUI）的「无线调试」会在重启/WiFi 断开/
//  省电策略下自动关闭，端口也会变。配对成功后执行一次 `adb tcpip 5555`，
//  明文的 5555 会一直开到下次重启、不依赖无线调试开关；
//  FrpcApp 的 relay 规则是「5555 活 → 走 5555」，于是这条路就稳了。
//

import SwiftUI

struct AdbMaintenanceView: View {

    @ObservedObject private var connectionManager = SessionConnectionManager.shared

    @State private var busy = false
    @State private var log = ""

    private var serial: String? { AdbToolService.shared.serial }
    private var ready: Bool { AdbToolService.shared.isReady }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("当前会话")
                    Spacer()
                    Text(serial ?? "未连接")
                        .foregroundColor(Theme.secondaryText)
                        .lineLimit(1)
                }
                HStack {
                    Text("ADB 工具就绪")
                    Spacer()
                    Text(ready ? "是" : "否")
                        .foregroundColor(ready ? .green : Theme.dangerForeground)
                }
            } header: {
                Text("状态")
            }

            Section {
                Button {
                    runTcpip()
                } label: {
                    HStack(spacing: 8) {
                        if busy {
                            ProgressView()
                        } else {
                            Image(systemName: "bolt.horizontal.circle")
                        }
                        Text("开启明文 5555（adb tcpip 5555）")
                    }
                }
                .disabled(busy || !ready)

                Button {
                    checkState()
                } label: {
                    Label("检查明文 5555 状态", systemImage: "stethoscope")
                }
                .disabled(busy || !ready)
            } header: {
                Text("持久化")
            } footer: {
                Text("无线调试在部分机型上会自己关（重启/WiFi 断开/省电策略）。执行一次 tcpip 5555 后，明文端口会一直开到下次重启，不依赖无线调试；relay 会优先走它。执行时 adbd 会重启，当前会话可能短暂断开，重新连接即可。")
            }

            if !log.isEmpty {
                Section {
                    Text(log)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                } header: {
                    Text("结果")
                }
            }
        }
        .navigationTitle("ADB 修复")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func runTcpip() {
        busy = true
        log = "正在执行 adb tcpip 5555…"
        Task {
            let result = await AdbToolService.shared.adb(["tcpip", "5555"])
            await MainActor.run {
                busy = false
                log = "exit \(result.code)\n\(result.trimmed.isEmpty ? "(无输出，adbd 正在重启，属正常)" : result.trimmed)"
            }
        }
    }

    private func checkState() {
        busy = true
        log = "正在检查…"
        Task {
            let result = await AdbToolService.shared.shell("getprop service.adb.tcp.port")
            await MainActor.run {
                busy = false
                let value = result.trimmed
                log = value == "5555"
                    ? "service.adb.tcp.port = 5555（明文端口已开启）"
                    : "service.adb.tcp.port = \(value.isEmpty ? "(空)" : value)（明文端口未开启）"
            }
        }
    }
}

//
//  MirrorPowerCommand.swift
//  Scrcpy Remote
//
//  投屏常驻快捷条上的「重启 / 关机」执行端。
//
//  分工：确认弹窗在 ObjC 侧（SDL_uikitviewcontroller+Extend.m，alert 必须盖在
//  投屏窗口上）；确认后发 kNotificationDevicePowerCommand 到这里，
//  用 AdbToolService 走当前会话的 adb 执行，失败再回发结果让 ObjC 弹提示。
//
//  重启/关机成功后 adb 必然断开 → 既有 Disconnected 流程会清会话、回标签页。
//

import Foundation

final class MirrorPowerCommand {

    static let shared = MirrorPowerCommand()

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCommand(_:)),
            name: Notification.Name("ScrcpyDevicePowerCommandNotification"),
            object: nil
        )
    }

    @objc private func handleCommand(_ notification: Notification) {
        guard let command = notification.userInfo?["command"] as? String,
              !command.isEmpty else {
            return
        }

        Task { @MainActor in
            guard AdbToolService.shared.isReady else {
                self.report(ok: false, message: AdbToolService.shared.notReadyReason)
                return
            }

            print("🔌 [MirrorPower] 执行设备电源命令：\(command)")
            let result = await AdbToolService.shared.shell(command)
            self.report(ok: result.ok, message: result.trimmed)
        }
    }

    private func report(ok: Bool, message: String) {
        NotificationCenter.default.post(
            name: Notification.Name("ScrcpyDevicePowerResultNotification"),
            object: nil,
            userInfo: ["ok": ok, "message": message]
        )
    }
}

//
//  ScreenshotService.swift
//  Scrcpy Remote
//
//  通过 adb 截取远端安卓屏幕（2026-10-18）。
//
//  ★ 不能用 `executeADBCommand` 直接拿 PNG —— 那个接口返回 String，
//    二进制会被破坏。做法：先 screencap 写成文件，再 `adb pull` 到本地沙盒。
//

import Foundation
import UIKit

enum ScreenshotService {

    /// 截一张当前设备屏幕（失败返回 nil）
    static func capture() async -> UIImage? {
        // /sdcard 大多数机器可写；不行再退回 /data/local/tmp
        let candidates = [
            "/sdcard/.scrcpy_script_shot.png",
            "/data/local/tmp/scrcpy_script_shot.png",
        ]

        for remote in candidates {
            let shoot = await AdbToolService.shared.shell("screencap -p \(remote)")
            guard shoot.ok else { continue }

            let local = NSTemporaryDirectory().appending("scrcpy_script_shot.png")
            try? FileManager.default.removeItem(atPath: local)

            let pulled = await AdbToolService.shared.pull(remotePath: remote, localPath: local)
            _ = await AdbToolService.shared.shell("rm -f \(remote)")

            guard pulled.ok, let image = UIImage(contentsOfFile: local), image.size.width > 0 else {
                continue
            }
            return image
        }

        return nil
    }
}

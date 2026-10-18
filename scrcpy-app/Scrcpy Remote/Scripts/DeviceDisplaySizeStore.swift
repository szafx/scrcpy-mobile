//
//  DeviceDisplaySizeStore.swift
//  Scrcpy Remote
//
//  取当前连接设备的显示分辨率（2026-10-18）。
//  脚本存归一化坐标，执行时要乘回这台设备真实的宽高。
//
//  `wm size` 输出形如：
//      Physical size: 1080x2400
//      Override size: 720x1600     ← 有 Override 时优先用它（有些机器开了分辨率缩放）
//

import Foundation
import UIKit

@MainActor
final class DeviceDisplaySizeStore {

    static let shared = DeviceDisplaySizeStore()

    private var cache: [String: (size: CGSize, at: Date)] = [:]
    private let ttl: TimeInterval = 30

    private init() {}

    /// 当前会话设备的分辨率
    func currentSize() async -> CGSize? {
        guard let serial = AdbToolService.shared.serial else { return nil }
        return await size(serial: serial)
    }

    func size(serial: String) async -> CGSize? {
        if let entry = cache[serial], Date().timeIntervalSince(entry.at) < ttl {
            return entry.size
        }

        let result = await AdbToolService.shared.shell("wm size", serial: serial)
        guard result.ok, let size = Self.parse(result.output) else { return nil }

        cache[serial] = (size, Date())
        return size
    }

    func invalidate() {
        cache.removeAll()
    }

    static func parse(_ output: String) -> CGSize? {
        var physical: CGSize?
        var override: CGSize?

        for line in output.split(separator: "\n") {
            let text = String(line).trimmingCharacters(in: .whitespaces)
            guard let colon = text.firstIndex(of: ":"),
                  let size = parseDimensions(String(text[text.index(after: colon)...])) else {
                continue
            }
            if text.lowercased().hasPrefix("override size") {
                override = size
            } else if text.lowercased().hasPrefix("physical size") {
                physical = size
            }
        }

        return override ?? physical
    }

    private static func parseDimensions(_ text: String) -> CGSize? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "x")
        guard parts.count == 2,
              let width = Double(String(parts[0]).trimmingCharacters(in: .whitespaces)),
              let height = Double(String(parts[1]).trimmingCharacters(in: .whitespaces)),
              width > 0, height > 0 else {
            return nil
        }
        return CGSize(width: width, height: height)
    }
}

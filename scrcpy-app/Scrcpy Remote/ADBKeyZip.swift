//
//  ADBKeyZip.swift
//  Scrcpy Remote
//
//  ADB 密钥导入的「选 zip 直接解压」（2026-10-27）。
//
//  为什么需要：iOS 的 `.fileImporter(allowedContentTypes: [.folder])` 在选文件夹时
//  经常点「打开」毫无反应（系统返回空 URL）。让用户直接选手里现成的 zip 更可靠，
//  而 iOS 没有公共的 zip 解压 API —— 这里实现一个最小 zip 读取器：
//    · 只支持 stored(0) / deflate(8)，不支持 ZIP64（密钥包只有几 KB）
//    · 从中央目录找 adbkey / adbkey.pub，按名字的 basename 匹配（忽略子目录）
//

import Foundation
import Compression

enum ADBKeyZip {

    /// 从 zip 里提取 adbkey / adbkey.pub 到指定目录。两个都找到才算成功。
    static func extractKeys(from zipURL: URL, to destination: URL) -> Bool {
        guard let data = try? Data(contentsOf: zipURL) else { return false }
        guard let entries = centralDirectoryEntries(in: data) else { return false }

        var extracted = 0
        for entry in entries {
            let name = (entry.name as NSString).lastPathComponent.lowercased()
            guard name == "adbkey" || name == "adbkey.pub" else { continue }
            guard let payload = payload(for: entry, in: data) else { continue }
            let target = destination.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: target)
            if (try? payload.write(to: target, options: .atomic)) != nil {
                extracted += 1
            }
        }
        return extracted == 2
    }

    // MARK: - Zip 结构

    private struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private static func u16(_ d: Data, _ i: Int) -> UInt16? {
        guard i >= 0, i + 2 <= d.count else { return nil }
        return UInt16(d[d.startIndex + i]) | (UInt16(d[d.startIndex + i + 1]) << 8)
    }

    private static func u32(_ d: Data, _ i: Int) -> UInt32? {
        guard i >= 0, i + 4 <= d.count else { return nil }
        return UInt32(d[d.startIndex + i])
            | (UInt32(d[d.startIndex + i + 1]) << 8)
            | (UInt32(d[d.startIndex + i + 2]) << 16)
            | (UInt32(d[d.startIndex + i + 3]) << 24)
    }

    /// 从文件末尾找 EOCD（签名 0x06054b50），再走中央目录
    private static func centralDirectoryEntries(in data: Data) -> [Entry]? {
        let searchLimit = min(data.count, 66_000)
        var eocdOffset: Int?
        var i = data.count - 22
        let lowerBound = max(0, data.count - searchLimit)

        while i >= lowerBound {
            if let sig = u32(data, i), sig == 0x0605_4b50 {
                eocdOffset = i
                break
            }
            i -= 1
        }
        guard let eocd = eocdOffset,
              let total = u16(data, eocd + 10).map(Int.init),
              let cdSize = u32(data, eocd + 12).map(Int.init),
              let cdOffset = u32(data, eocd + 16).map(Int.init),
              cdOffset + cdSize <= data.count else {
            return nil
        }

        var entries: [Entry] = []
        var cursor = cdOffset
        for _ in 0..<total {
            guard let sig = u32(data, cursor), sig == 0x0201_4b50 else { break }
            guard let method = u16(data, cursor + 10),
                  let compSize = u32(data, cursor + 20).map(Int.init),
                  let uncompSize = u32(data, cursor + 24).map(Int.init),
                  let nameLen = u16(data, cursor + 28).map(Int.init),
                  let extraLen = u16(data, cursor + 30).map(Int.init),
                  let commentLen = u16(data, cursor + 32).map(Int.init),
                  let localOffset = u32(data, cursor + 42).map(Int.init),
                  cursor + 46 + nameLen <= data.count else {
                return nil
            }
            let nameStart = data.startIndex + cursor + 46
            let name = String(decoding: data[nameStart..<(nameStart + nameLen)], as: UTF8.self)
            entries.append(Entry(name: name,
                                 method: method,
                                 compressedSize: compSize,
                                 uncompressedSize: uncompSize,
                                 localHeaderOffset: localOffset))
            cursor += 46 + nameLen + extraLen + commentLen
        }
        return entries
    }

    /// 读 local header 定位数据，再按压缩方式解压
    private static func payload(for entry: Entry, in data: Data) -> Data? {
        let lh = entry.localHeaderOffset
        guard let sig = u32(data, lh), sig == 0x0403_4b50,
              let nameLen = u16(data, lh + 26).map(Int.init),
              let extraLen = u16(data, lh + 28).map(Int.init) else {
            return nil
        }
        let start = lh + 30 + nameLen + extraLen
        let end = start + entry.compressedSize
        guard start >= 0, end <= data.count else { return nil }

        let raw = data.subdata(in: (data.startIndex + start)..<(data.startIndex + end))

        switch entry.method {
        case 0:
            return raw
        case 8:
            return inflate(raw, expectedSize: entry.uncompressedSize)
        default:
            return nil
        }
    }

    private static func inflate(_ data: Data, expectedSize: Int) -> Data? {
        guard expectedSize > 0, expectedSize < 10 * 1024 * 1024 else { return nil }

        var output = [UInt8](repeating: 0, count: expectedSize)
        let written = data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
            guard let base = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(&output, expectedSize,
                                             base, data.count,
                                             nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else { return nil }
        return Data(output[0..<written])
    }
}

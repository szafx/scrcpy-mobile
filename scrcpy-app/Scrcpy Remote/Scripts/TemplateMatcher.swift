//
//  TemplateMatcher.swift
//  Scrcpy Remote
//
//  识图点击的模板匹配（2026-10-18）。
//
//  为什么不用 Vision：Vision 没有「找这张小图在屏幕哪里」的模板匹配接口。
//  这里实现一个够用的归一化互相关（NCC）：
//    · 屏幕灰度降采样到宽 ~240，模板按「当前屏宽 / 参考屏宽」缩放
//    · 粗搜 stride=2 + 峰值邻域 stride=1 细化
//    · 多尺度 0.9 / 1.0 / 1.1 兜住不同分辨率、UI 缩放的差异
//    · 返回归一化中心（0…1），调用方乘屏幕实际像素去 input tap
//

import Foundation
import UIKit

struct TemplateMatch {
    /// 归一化中心（0…1，左上为原点）
    let center: CGPoint
    let score: Double
}

private struct GrayImage {
    let width: Int
    let height: Int
    let pixels: [Float]
}

enum TemplateMatcher {

    /// 最近一次匹配的最高分（没找到目标时也能打日志）
    static var lastBestScore: Double?

    static func find(template: UIImage,
                     in screen: UIImage,
                     referenceWidth: CGFloat,
                     threshold: Double) -> TemplateMatch? {

        lastBestScore = nil
        guard referenceWidth > 1,
              let screenCG = screen.cgImage,
              let templateCG = template.cgImage else {
            return nil
        }

        let templateArea = templateCG.width * templateCG.height
        // 模板很大时把搜索图降得更小，避免纯 Swift 循环太慢
        let searchWidth = templateArea > 5000 ? 160 : 240
        let screenW = searchWidth
        let screenH = max(1, Int((CGFloat(searchWidth) * CGFloat(screenCG.height) / CGFloat(screenCG.width)).rounded()))

        guard let screenGray = gray(screenCG, width: screenW, height: screenH) else { return nil }

        // 参考分辨率下的模板像素 → 当前搜索图里的像素
        let baseScale = CGFloat(searchWidth) / referenceWidth

        var best: (score: Double, x: Int, y: Int, tW: Int, tH: Int)?

        for factor in [CGFloat(0.9), 1.0, 1.1] {
            let tW = Int((CGFloat(templateCG.width) * baseScale * factor).rounded())
            let tH = Int((CGFloat(templateCG.height) * baseScale * factor).rounded())
            guard tW >= 6, tH >= 6, tW <= screenW, tH <= screenH else { continue }
            guard let templateGray = gray(templateCG, width: tW, height: tH) else { continue }

            guard var result = coarseSearch(screenGray, templateGray, stride: 2) else { continue }
            if let refined = refine(screenGray, templateGray, around: result, radius: 3) {
                result = refined
            }

            if best == nil || result.score > best!.score {
                best = (result.score, result.x, result.y, tW, tH)
            }
            if result.score > (lastBestScore ?? -1) {
                lastBestScore = result.score
            }
        }

        guard let best else { return nil }

        let centerX = (CGFloat(best.x) + CGFloat(best.tW) / 2.0) / CGFloat(screenW)
        let centerY = (CGFloat(best.y) + CGFloat(best.tH) / 2.0) / CGFloat(screenH)
        let center = CGPoint(x: min(1.0, max(0.0, centerX)),
                             y: min(1.0, max(0.0, centerY)))

        guard best.score >= threshold else { return nil }
        return TemplateMatch(center: center, score: best.score)
    }

    // MARK: - 搜索

    private static func coarseSearch(_ screen: GrayImage,
                                     _ template: GrayImage,
                                     stride: Int) -> (score: Double, x: Int, y: Int)? {
        search(screen, template,
               xRange: 0...(screen.width - template.width),
               yRange: 0...(screen.height - template.height),
               stride: stride)
    }

    private static func refine(_ screen: GrayImage,
                               _ template: GrayImage,
                               around best: (score: Double, x: Int, y: Int),
                               radius: Int) -> (score: Double, x: Int, y: Int)? {
        let minX = max(0, best.x - radius)
        let maxX = min(screen.width - template.width, best.x + radius)
        let minY = max(0, best.y - radius)
        let maxY = min(screen.height - template.height, best.y + radius)
        guard minX <= maxX, minY <= maxY else { return nil }

        return search(screen, template, xRange: minX...maxX, yRange: minY...maxY, stride: 1)
    }

    private static func search(_ screen: GrayImage,
                               _ template: GrayImage,
                               xRange: ClosedRange<Int>,
                               yRange: ClosedRange<Int>,
                               stride: Int) -> (score: Double, x: Int, y: Int)? {

        let tW = template.width
        let tH = template.height
        let n = Float(tW * tH)

        var tSum: Float = 0
        var tSum2: Float = 0
        for value in template.pixels {
            tSum += value
            tSum2 += value * value
        }
        let tVar = tSum2 - tSum * tSum / n
        guard tVar > 1e-3 else { return nil }
        let tNorm = sqrt(tVar)

        var bestScore = -2.0
        var bestX = xRange.lowerBound
        var bestY = yRange.lowerBound

        var y = yRange.lowerBound
        while y <= yRange.upperBound {
            var x = xRange.lowerBound
            while x <= xRange.upperBound {
                var cross: Float = 0
                var sSum: Float = 0
                var sSum2: Float = 0

                for j in 0..<tH {
                    let sRow = (y + j) * screen.width + x
                    let tRow = j * tW
                    for i in 0..<tW {
                        let sValue = screen.pixels[sRow + i]
                        let tValue = template.pixels[tRow + i]
                        cross += sValue * tValue
                        sSum += sValue
                        sSum2 += sValue * sValue
                    }
                }

                let sVar = sSum2 - sSum * sSum / n
                if sVar > 1e-3 {
                    let score = Double((cross - sSum * tSum / n) / (sqrt(sVar) * tNorm))
                    if score > bestScore {
                        bestScore = score
                        bestX = x
                        bestY = y
                    }
                }

                x += stride
            }
            y += stride
        }

        guard bestScore > -2 else { return nil }
        return (bestScore, bestX, bestY)
    }

    // MARK: - 灰度化

    /// 画进灰度 CGContext（左上为原点）
    private static func gray(_ cgImage: CGImage, width: Int, height: Int) -> GrayImage? {
        guard width > 0, height > 0 else { return nil }

        var bytes = [UInt8](repeating: 0, count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()

        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: width,
                                          space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
                return false
            }
            context.interpolationQuality = .medium
            // 翻转成左上原点，和 UIKit / input tap 的坐标系一致
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        var pixels = [Float](repeating: 0, count: width * height)
        for i in 0..<pixels.count {
            pixels[i] = Float(bytes[i])
        }
        return GrayImage(width: width, height: height, pixels: pixels)
    }
}

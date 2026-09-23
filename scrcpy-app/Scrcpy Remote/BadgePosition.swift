//
//  BadgePosition.swift
//  Scrcpy Remote
//
//  气泡的位置状态 —— 视图和窗口共享。
//
//  为什么需要共享：气泡既要**能拖**（窗口得吃触摸），又要**不挡操作**
//  （窗口得放行触摸）。唯一能两全的办法是让窗口精确知道
//  「气泡现在占屏幕上哪一块」—— 而那块位置由 SwiftUI 视图决定、拖动时会变，
//  所以由视图上报矩形、窗口读取。
//

import SwiftUI

@MainActor
final class BadgePosition: ObservableObject {

    static let shared = BadgePosition()

    /// 拖动偏移（相对初始的右上角位置）。
    /// 存 UserDefaults —— 用户把气泡挪开后，下次进来还在那儿。
    @Published var offset: CGSize = .zero

    /// 气泡在屏幕坐标系里实际占的矩形（含一点抓取余量），由视图上报。
    /// 窗口的 hitTest 只看它 —— 只在这块范围内才吃触摸。
    @Published var hitFrame: CGRect = .zero

    /// 抓取区比视觉尺寸外扩多少。手指没那么准，
    /// 视觉上小巧才不挡视线，但抓手要留够。
    static let grabMargin: CGFloat = 14

    private let defaultsKey = "latency_badge.offset"

    private init() {
        load()
    }

    func save() {
        UserDefaults.standard.set([offset.width, offset.height], forKey: defaultsKey)
    }

    private func load() {
        guard let values = UserDefaults.standard.array(forKey: defaultsKey) as? [Double],
              values.count == 2 else { return }
        offset = CGSize(width: values[0], height: values[1])
    }
}

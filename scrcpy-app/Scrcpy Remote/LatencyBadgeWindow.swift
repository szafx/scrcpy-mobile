//
//  LatencyBadgeWindow.swift
//  Scrcpy Remote
//
//  把延迟气泡浮在**投屏画面之上**。
//
//  为什么用独立 UIWindow，而不是在 MainContentView 里加 overlay：
//    投屏画面是 SDL 建的原生 UIKit 窗口，盖在 SwiftUI 之上 ——
//    而且 App 自己的逻辑就是「connectionStatus 一到 SDLWindowAppeared，
//    SwiftUI 的 overlay 就隐藏」（MainContentView 的 shouldShowConnectionStatusView）。
//    所以 SwiftUI 层的 overlay 这时候根本看不见，只能另起一个窗口浮上去。
//
//  为什么整窗 isUserInteractionEnabled = false：
//    气泡只要「看」，不要「点」。关掉交互它就彻底穿透，
//    既不会挡住投屏的手势/触摸，也不用去折腾 hitTest 那套。
//    以后要做「点一下展开」，得换成自定义 PassthroughWindow 重写 hitTest。
//

import SwiftUI
import UIKit

@MainActor
final class LatencyBadgeWindow {

    static let shared = LatencyBadgeWindow()

    private var window: UIWindow?

    private init() {}

    var isShowing: Bool { window != nil }

    /// 连接成功、投屏画面出来后调用。重复调用是安全的。
    func show() {
        guard window == nil else { return }

        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else {
            print("[LatencyBadgeWindow] 找不到 UIWindowScene，气泡不显示")
            return
        }

        let newWindow = PassthroughWindow(windowScene: scene)
        // 比普通窗口高一档就够，别用 .alert 那档，免得盖住系统弹窗
        newWindow.windowLevel = .normal + 1
        newWindow.backgroundColor = .clear
        newWindow.isOpaque = false
        // 气泡本身要能点（点开看抖动和目标地址），
        // 但**只有气泡那一小块**吃事件，其余全部穿透给下面的投屏窗口 ——
        // 具体由 PassthroughWindow.hitTest 控制。
        newWindow.isUserInteractionEnabled = true
        newWindow.rootViewController = UIHostingController(rootView: LatencyBadgeHost())
        newWindow.rootViewController?.view.backgroundColor = .clear

        newWindow.isHidden = false
        window = newWindow

        LatencyMonitor.shared.start()
        print("[LatencyBadgeWindow] 气泡已显示")
    }

    /// 断开连接时调用。
    func hide() {
        guard window != nil else { return }
        window?.isHidden = true
        window = nil
        LatencyMonitor.shared.stop()
        print("[LatencyBadgeWindow] 气泡已隐藏")
    }
}

/// 只让气泡那一小块吃触摸，其余位置穿透给下面的投屏窗口。
///
/// 判据：`super.hitTest` 返回的如果是**透传容器本身**（rootViewController.view），
/// 说明这个点没落在气泡上 —— 这时返回 nil，事件就会继续传给下层窗口。
/// 落在气泡上时返回的是气泡内部的视图，正常响应。
private final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        return hit === rootViewController?.view ? nil : hit
    }
}

/// 气泡的摆放：贴右上角，留出安全区。
///
/// 注意这里**不能**加 `.allowsHitTesting(false)` —— 那会让气泡点不动。
/// 触摸要不要穿透由 PassthroughWindow.hitTest 统一决定。
private struct LatencyBadgeHost: View {
    var body: some View {
        VStack {
            HStack {
                Spacer()
                LatencyBadgeView()
                    .padding(.trailing, 10)
                    .padding(.top, 4)
            }
            Spacer()
        }
    }
}

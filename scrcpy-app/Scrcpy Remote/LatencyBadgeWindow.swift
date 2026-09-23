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
        // 先清临时提示（「正在重连…」之类），恢复常规读数。
        // ★ 必须放在下面那个 guard 之前 —— 窗口还在显示时 show() 会提前返回，
        //   放后面就清不掉了。
        LatencyMonitor.shared.setBanner(nil)

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

        // 连上了 —— 把「正在重连…」之类的临时提示清掉，恢复常规读数
        LatencyMonitor.shared.setBanner(nil)
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

    /// 显示一条临时提示（重连用）。
    ///
    /// ★ 为什么走这个窗口：投屏画面是 SDL 建的**原生窗口**，盖在 SwiftUI 之上，
    ///   所以 `ConnectionStatusView` 那类 SwiftUI 状态界面在投屏期间**根本看不见** ——
    ///   用户实测「重连的时候我根本看不到提示，只能看到卡住」。
    ///   气泡这个窗浮在 SDL 之上，是这时候唯一能显示东西的地方。
    func showBanner(_ message: String) {
        if !isShowing { show() }   // 断线时窗口可能已经被 hide 掉
        LatencyMonitor.shared.setBanner(message)
        print("[LatencyBadgeWindow] 横幅：\(message)")
    }

    /// 清掉临时提示，恢复常规读数。
    func clearBanner() {
        LatencyMonitor.shared.setBanner(nil)
    }
}

/// 只让**右上角气泡那一小块矩形**吃触摸，其余位置一律放行给下面的投屏窗口。
///
/// ★★ 这里踩过一个坑，别再改回去：
///   宿主视图是个**撑满全屏**的 VStack（用 Spacer 把气泡推到右上角），
///   所以点击落在空白处时，`super.hitTest` 命中的是那个全屏容器、
///   而不是"最外层 view" —— 之前按 `hit === rootViewController?.view` 判断，
///   结果整屏的触摸都被这个透明窗口吃掉，投屏**完全点不动**，
///   只有气泡自己能点。用户实测：「无法点击，无法控制，只有右上角的延迟能点」。
///
///   改成按**坐标矩形**判断最稳妥：只有点在右上角那块才响应。
private final class PassthroughWindow: UIWindow {

    /// 气泡在窗口坐标系里占的矩形（比气泡本身放大一圈，兼顾展开态）
    private var badgeRect: CGRect {
        let width: CGFloat = 170
        let height: CGFloat = 130
        let topInset = windowScene?.statusBarManager?.statusBarFrame.height ?? 44
        return CGRect(x: bounds.width - width - 10,
                      y: topInset,
                      width: width,
                      height: height)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // 不在气泡范围内 —— 直接返回 nil，事件继续传给下面的投屏窗口
        guard badgeRect.contains(point) else { return nil }
        return super.hitTest(point, with: event)
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

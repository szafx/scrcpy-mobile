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
        // 连接成功 = 在投屏界面了，允许浮层显示（回主页时会被 suppressAndHide 关掉）
        allowsDisplay = true

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
        // 要能拖，所以开着交互 —— 但**只有气泡那一小块**真的吃事件，
        // 其余全部穿透给投屏窗口，具体由 PassthroughWindow.hitTest 控制。
        newWindow.isUserInteractionEnabled = true
        newWindow.rootViewController = UIHostingController(rootView: LatencyBadgeHost())
        newWindow.rootViewController?.view.backgroundColor = .clear

        newWindow.isHidden = false
        window = newWindow

        // ★★ 拖动用 **UIKit 手势**，不用 SwiftUI 的 DragGesture。
        //
        //   实测：SwiftUI 的 DragGesture 在这个独立窗口里压根不响应
        //   （命中区日志显示 hitFrame 是正确的、窗口也吃到了触摸，
        //     但手势就是不触发）。而 App 自带的菜单图标能随意拖动 ——
        //   它用的正是 UIPanGestureRecognizer。照抄它最省事。
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.cancelsTouchesInView = true
        pan.delaysTouchesEnded = true
        newWindow.rootViewController?.view.addGestureRecognizer(pan)

        // 连上了 —— 把「正在重连…」之类的临时提示清掉，恢复常规读数
        LatencyMonitor.shared.setBanner(nil)
        LatencyMonitor.shared.start()
        print("[LatencyBadgeWindow] 气泡已显示")
    }

    /// 拖动气泡。偏移累加到 BadgePosition.offset，抬手时存盘。
    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let position = BadgePosition.shared

        switch gesture.state {
        case .changed:
            let t = gesture.translation(in: gesture.view)
            position.dragOffset = CGSize(width: t.x, height: t.y)

        case .ended, .cancelled:
            let t = gesture.translation(in: gesture.view)
            position.offset = CGSize(width: position.offset.width + t.x,
                                     height: position.offset.height + t.y)
            position.dragOffset = .zero
            position.save()
            print("[LatencyBadgeWindow] 气泡移到 \(position.offset)")

        default:
            break
        }
    }

    /// 断开连接时调用。
    func hide() {
        guard window != nil else { return }
        window?.isHidden = true
        window = nil
        LatencyMonitor.shared.stop()
        print("[LatencyBadgeWindow] 气泡已隐藏")
    }

    /// 连接开始 / 投屏出现时调用 —— 这时才允许浮层显示。
    func allowDisplay() {
        allowsDisplay = true
    }

    /// 回到主页时调用 —— 收掉浮层，并禁止之后再冒出来。
    ///
    /// ★ 这一步是必须的：回到主页意味着这次连接结束了，
    ///   后面就算网络又变化，也不该再有「正在重连」浮在主页上
    ///   （用户原话：「回到主页，就不能尝试重连了，只能让用户手动去连」）。
    func suppressAndHide() {
        allowsDisplay = false
        hide()
    }

    /// 显示一条临时提示（重连用）。
    ///
    /// ★ 为什么走这个窗口：投屏画面是 SDL 建的**原生窗口**，盖在 SwiftUI 之上，
    ///   所以 `ConnectionStatusView` 那类 SwiftUI 状态界面在投屏期间**根本看不见** ——
    ///   用户实测「重连的时候我根本看不到提示，只能看到卡住」。
    ///   气泡这个窗浮在 SDL 之上，是这时候唯一能显示东西的地方。
    ///
    /// ★★ 但它**只在投屏/连接界面存在**（见 allowsDisplay 的说明）：
    ///   用户已经回到主页了，还浮着一条「正在重连」是很怪的 ——
    ///   回主页意味着这次连接结束了，该由用户手动决定要不要再连。
    func showBanner(_ message: String) {
        guard allowsDisplay else {
            print("[LatencyBadgeWindow] 已经回到主页，不显示重连横幅")
            return
        }
        if !isShowing { show() }   // 断线时窗口可能已经被 hide 掉
        LatencyMonitor.shared.setBanner(message)
        print("[LatencyBadgeWindow] 横幅：\(message)")
    }

    /// 允不允许显示浮层。
    ///
    /// 判据就是用户提的那条：**气泡只属于「正在连接的界面」**。
    /// 回到主页 = 这次连接结束 = 不该再有任何自动重连的痕迹，只能用户手动发起。
    ///
    /// 由 MainContentView 在进入/离开主页时设置。
    var allowsDisplay: Bool = true

    /// 清掉临时提示，恢复常规读数。
    func clearBanner() {
        LatencyMonitor.shared.setBanner(nil)
    }
}

/// 只让**气泡当前占的那块**吃触摸，其余位置一律放行给下面的投屏窗口。
///
/// ★★ 这里踩过两次坑，现在的做法是第三次：
///
///   坑一（吃全屏）：宿主是个撑满全屏的 VStack（用 Spacer 把气泡推到右上角），
///   点击落在空白处时 `super.hitTest` 命中的是那个全屏容器而不是最外层 view，
///   按 `hit === rootViewController?.view` 判断的结果是——整屏触摸都被吃掉，
///   投屏**完全点不动**（用户实测：「无法点击，无法控制，只有右上角的延迟能点」）。
///
///   坑二（隐形区域）：改成按坐标矩形判断后，矩形写成了 170×130，
///   而气泡实际只有约 110×30 —— 于是气泡周围一大片**看不见的地方**也在吃触摸，
///   用户按不到底下投屏画面里的控件（「有些手机界面位置按不了」）。
///
///   现在的做法：矩形**由视图实时上报**（BadgePosition.hitFrame），
///   而不是在窗口里猜。这样：
///     - 拖动气泡 → 矩形跟着动 → 拖到哪儿就在哪儿能抓住
///     - 气泡很小 → 矩形就小 → 不挡操作
///   而且只在这个矩形内才吃触摸，其余全部穿透。
private final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let frame = BadgePosition.shared.hitFrame
        guard !frame.isEmpty, frame.contains(point) else { return nil }
        return super.hitTest(point, with: event)
    }
}

/// 气泡的摆放：默认贴右上角，**可以拖到任意位置**。
///
/// 拖动的意义不只是"挪开" —— 它和"不吃触摸"这件事是配套的：
/// 气泡平时只吃自己那块（不挡操作），你要动它时按住它就行。
///
/// 位置存盘（BadgePosition），下次进来还在你放的地方。
///
/// ★ 这里还负责**把气泡的实时矩形上报给窗口**（BadgePosition.hitFrame）——
///   窗口的 hitTest 只看这块矩形，所以拖到哪儿就在哪儿能抓住。
private struct LatencyBadgeHost: View {

    @ObservedObject private var badge = BadgePosition.shared

    var body: some View {
        VStack {
            HStack {
                Spacer()
                LatencyBadgeView()
                    .padding(.trailing, 10)
                    .padding(.top, 4)
                    .offset(x: badge.offset.width + badge.dragOffset.width,
                            y: badge.offset.height + badge.dragOffset.height)
                    .background(
                        // 把气泡当前的屏幕矩形报出去 —— 窗口的 hitTest 要用
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: BadgeFrameKey.self,
                                value: geo.frame(in: .global)
                            )
                        }
                    )
                    // 拖动由 UIKit 手势处理（见 LatencyBadgeWindow.handlePan），
                    // 这里不用 DragGesture —— 实测它在这个独立窗口里不触发。
            }
            Spacer()
        }
        .onPreferenceChange(BadgeFrameKey.self) { frame in
            // 往外扩一点当抓取区：视觉上小巧，但手指按得中
            let hit = frame.insetBy(dx: -BadgePosition.grabMargin,
                                    dy: -BadgePosition.grabMargin)
            // 不打印 —— 延迟数字一变宽度就变，这里会刷屏、把别的日志全淹了
            BadgePosition.shared.hitFrame = hit
        }
    }
}

/// 用来把气泡的屏幕矩形从视图里传出来
private struct BadgeFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

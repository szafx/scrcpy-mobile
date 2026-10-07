//
//  LatencyBadgeWindow.swift
//  Scrcpy Remote
//
//  把延迟气泡浮在**投屏画面之上**。
//
//  为什么用独立 UIWindow，而不是在 MainContentView 里加 overlay：
//    投屏画面是 SDL 建的原生 UIKit 窗口，盖在 SwiftUI 之上 ——
//    而且 App 自己的逻辑就是「connectionStatus 一到 SDLWindowAppeared，
//    SwiftUI 的 overlay 就隐藏」。所以 SwiftUI 层的 overlay 这时候根本看不见，
//    只能另起一个窗口浮上去。
//
//  ★ 2026-10-07 深夜：第三次重写，从 SwiftUI 换成**纯 UIKit**。
//
//    前两版（都在 SwiftUI 里）踩的坑：
//      坑一：宿主是撑满全屏的 VStack，空白处的点击被整窗吃掉，投屏点不动；
//      坑二：改成按坐标矩形判断，矩形尺寸写死（170×130 > 气泡实际 ~110×22），
//            气泡周围一大片隐形区域也在吃触摸；
//      坑三（用户实测：「拖不动气泡本体，只能在它右上角某个位置拖」）：
//            气泡用 .offset() 移动，而 .offset 只动画面、**不动布局几何** ——
//            GeometryReader 上报的「可抓取矩形」永远停在初始的右上角位置，
//            气泡拖到哪都抓不住，抓住的是"出生点"。
//
//    这次的做法（照抄 App 里能流畅拖动的菜单图标那套 UIKit）：
//      - 气泡就是一个普通 UIView，UIPanGestureRecognizer 直接挂在**它自己**身上；
//      - 窗口的 hitTest 只问一句「你点中的是不是气泡（或它的子视图）」，
//        是就吃、不是就穿透 —— 不用任何坐标上报、不用 preference、不用猜矩形；
//      - 位置用「右上角锚点」管理，尺寸随文本自适应，拖动时锚点跟手走。
//
//    位置存盘沿用 BadgePosition（UserDefaults 里那对偏移量语义不变），
//    所以升级后气泡还停在用户原来放的地方。
//

import UIKit

@MainActor
final class LatencyBadgeWindow {

    static let shared = LatencyBadgeWindow()

    private var window: PassthroughWindow?
    private var badge: LatencyBadgeUIKitView?

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
        newWindow.rootViewController = UIViewController()
        newWindow.rootViewController?.view.backgroundColor = .clear

        let badgeView = LatencyBadgeUIKitView()
        newWindow.addSubview(badgeView)
        newWindow.badgeRef = badgeView

        newWindow.isHidden = false
        window = newWindow
        badge = badgeView

        badgeView.install(in: newWindow)
        badgeView.startUpdating()

        LatencyMonitor.shared.start()
        print("[LatencyBadgeWindow] 气泡已显示（UIKit 版）")
    }

    /// 断开连接时调用。
    func hide() {
        guard window != nil else { return }
        badge?.stopUpdating()
        window?.isHidden = true
        window = nil
        badge = nil
        LatencyMonitor.shared.stop()
        print("[LatencyBadgeWindow] 气泡已隐藏")
    }

    /// 连接开始 / 投屏出现时调用 —— 这时才允许浮层显示。
    func allowDisplay() {
        allowsDisplay = true
    }

    /// 回到主页时调用 —— 收掉浮层，并禁止之后再冒出来。
    func suppressAndHide() {
        allowsDisplay = false
        hide()
    }

    /// 显示一条临时提示（重连用）。
    func showBanner(_ message: String) {
        guard allowsDisplay else {
            print("[LatencyBadgeWindow] 已经回到主页，不显示重连横幅")
            return
        }
        if !isShowing { show() }   // 断线时窗口可能已经被 hide 掉
        LatencyMonitor.shared.setBanner(message)
        print("[LatencyBadgeWindow] 横幅：\(message)")
    }

    /// 清掉临时提示，恢复常规读数。
    func clearBanner() {
        LatencyMonitor.shared.setBanner(nil)
    }

    /// 允不允许显示浮层。
    ///
    /// 判据就是用户提的那条：**气泡只属于「正在连接的界面」**。
    /// 回到主页 = 这次连接结束 = 不该再有任何自动重连的痕迹，只能用户手动发起。
    /// 由 MainContentView 在进入/离开主页时设置。
    var allowsDisplay: Bool = true
}

// MARK: - 只吃气泡那块的穿透窗口

/// 只让**气泡本身**吃触摸，其余位置一律放行给下面的投屏窗口。
///
/// 做法=问一句「点中的是不是气泡（或它的后代）」——
/// 不再依赖 SwiftUI 上报的坐标矩形（那套在 .offset 面前会错位，见文件头坑三）。
private final class PassthroughWindow: UIWindow {

    weak var badgeRef: UIView?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        guard let badge = badgeRef, hit === badge || hit.isDescendant(of: badge) else {
            return nil   // 不是气泡 → 穿透给投屏窗口
        }
        return hit
    }
}

// MARK: - 气泡本体（纯 UIKit）

/// 圆点 + 连接方式 + 延迟数字的小胶囊。可拖动（抓手就是它自己）。
///
/// 布局全手工算：视图按「右上角锚点 + 自适应宽度」摆放 ——
/// 延迟数字位数变化时向左伸长，右边和上边保持不动（观感与旧版一致）。
@MainActor
final class LatencyBadgeUIKitView: UIView {

    private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
    private let dotView = UIView()
    private let kindLabel = UILabel()
    private let msLabel = UILabel()

    private var timer: Timer?
    private weak var hostWindow: UIWindow?
    private var dragStartCorner: CGPoint = .zero

    /// 气泡右上角锚点（窗口坐标）。默认 = 右边内缩 10、安全区顶下 4，
    /// 与旧版 SwiftUI 布局一致 —— 存盘的偏移量语义不变。
    private var corner: CGPoint = .zero

    private let dotSize: CGFloat = 6
    private let padH: CGFloat = 8
    private let padV: CGFloat = 4
    private let gap1: CGFloat = 4
    private let gap2: CGFloat = 5
    private let defaultInsetRight: CGFloat = 10
    private let defaultInsetTop: CGFloat = 4

    init() {
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        backgroundColor = .clear
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.22
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 0, height: 1)
        layer.borderWidth = 0.5
        layer.borderColor = UIColor.white.withAlphaComponent(0.15).cgColor

        blurView.isUserInteractionEnabled = false
        addSubview(blurView)

        dotView.layer.cornerRadius = dotSize / 2
        dotView.backgroundColor = .gray
        addSubview(dotView)

        kindLabel.font = .systemFont(ofSize: 10, weight: .medium)
        kindLabel.textColor = .label
        addSubview(kindLabel)

        msLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        msLabel.textColor = .gray
        addSubview(msLabel)

        // 抓手就是这个视图本身 —— 按在哪都能拖（坑三的根治）
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)
    }

    // MARK: - 生命周期

    func install(in window: UIWindow) {
        hostWindow = window
        let base = defaultCorner()
        let saved = BadgePosition.shared.offset
        corner = CGPoint(x: base.x + saved.width, y: base.y + saved.height)
        refresh(force: true)
    }

    func startUpdating() {
        stopUpdating()
        // 0.5 秒刷一次文本；LatencyMonitor 自己 2 秒才探一次，这里只是取数。
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        refresh(force: true)
    }

    func stopUpdating() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - 刷新内容

    private func refresh(force: Bool = false) {
        let monitor = LatencyMonitor.shared
        var needRelayout = force

        if let banner = monitor.banner {
            // 临时横幅（重连提示）：整条换成提示文字
            if kindLabel.text != banner { kindLabel.text = banner; needRelayout = true }
            if !msLabel.isHidden { msLabel.isHidden = true; needRelayout = true }
            dotView.backgroundColor = Self.color(ms: nil)
        } else {
            let kindText = monitor.kind.label
            if kindLabel.text != kindText { kindLabel.text = kindText; needRelayout = true }
            if msLabel.isHidden { msLabel.isHidden = false; needRelayout = true }

            let ms = monitor.latencyMs
            let msText: String
            if let ms { msText = String(format: "%.0f ms", ms) } else { msText = "—" }
            if msLabel.text != msText { msLabel.text = msText; needRelayout = true }

            let color = Self.color(ms: ms)
            msLabel.textColor = color
            dotView.backgroundColor = color
        }

        if needRelayout {
            relayout()
        }
    }

    /// 延迟分档：跟实际手感对齐，别用 ping 那套阈值（那条路上 ICMP 会虚高）
    private static func color(ms: Double?) -> UIColor {
        guard let ms else { return .gray }
        if ms < 40 { return UIColor(red: 0.30, green: 0.85, blue: 0.45, alpha: 1.0) }   // 跟手
        if ms < 90 { return UIColor(red: 0.95, green: 0.78, blue: 0.30, alpha: 1.0) }   // 可用
        if ms < 160 { return UIColor(red: 0.98, green: 0.55, blue: 0.25, alpha: 1.0) }  // 有点顿
        return UIColor(red: 0.95, green: 0.35, blue: 0.35, alpha: 1.0)                  // 明显卡
    }

    // MARK: - 手工布局

    private func defaultCorner() -> CGPoint {
        guard let w = hostWindow else { return .zero }
        return CGPoint(x: w.bounds.width - defaultInsetRight,
                       y: w.safeAreaInsets.top + defaultInsetTop)
    }

    private func clampCorner() {
        guard let w = hostWindow else { return }
        let inset: CGFloat = 4
        corner.x = min(max(corner.x, inset + 60), w.bounds.width - inset)
        corner.y = min(max(corner.y, w.safeAreaInsets.top + inset), w.bounds.height - inset)
    }

    private func relayout() {
        kindLabel.sizeToFit()
        if !msLabel.isHidden { msLabel.sizeToFit() }

        var width = padH * 2 + dotSize + gap1 + kindLabel.frame.width
        if !msLabel.isHidden { width += gap2 + msLabel.frame.width }
        var height = max(dotSize, kindLabel.frame.height)
        if !msLabel.isHidden { height = max(height, msLabel.frame.height) }
        height += padV * 2
        height = max(height, 20)
        let size = CGSize(width: ceil(width), height: ceil(height))

        clampCorner()
        frame = CGRect(x: corner.x - size.width, y: corner.y,
                       width: size.width, height: size.height)

        blurView.frame = bounds
        blurView.layer.cornerRadius = size.height / 2
        blurView.clipsToBounds = true

        layer.cornerRadius = size.height / 2
        layer.shadowPath = UIBezierPath(roundedRect: bounds,
                                        cornerRadius: size.height / 2).cgPath

        let midY = size.height / 2
        dotView.frame = CGRect(x: padH, y: midY - dotSize / 2,
                               width: dotSize, height: dotSize)

        var x = padH + dotSize + gap1
        kindLabel.frame = CGRect(x: x, y: midY - kindLabel.frame.height / 2,
                                 width: kindLabel.frame.width, height: kindLabel.frame.height)
        x += kindLabel.frame.width + gap2
        if !msLabel.isHidden {
            msLabel.frame = CGRect(x: x, y: midY - msLabel.frame.height / 2,
                                   width: msLabel.frame.width, height: msLabel.frame.height)
        }
    }

    // MARK: - 拖动

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let w = hostWindow else { return }
        let t = gesture.translation(in: w)

        switch gesture.state {
        case .began:
            dragStartCorner = corner

        case .changed:
            corner = CGPoint(x: dragStartCorner.x + t.x, y: dragStartCorner.y + t.y)
            relayout()

        case .ended, .cancelled:
            corner = CGPoint(x: dragStartCorner.x + t.x, y: dragStartCorner.y + t.y)
            clampCorner()
            relayout()
            // 存盘（相对默认右上角的偏移，语义与旧版一致）
            let base = defaultCorner()
            let position = BadgePosition.shared
            position.offset = CGSize(width: corner.x - base.x, height: corner.y - base.y)
            position.save()
            print("[LatencyBadgeWindow] 气泡移到 \(position.offset)")

        default:
            break
        }
    }
}

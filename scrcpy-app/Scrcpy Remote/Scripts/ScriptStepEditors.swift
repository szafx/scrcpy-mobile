//
//  ScriptStepEditors.swift
//  Scrcpy Remote
//
//  单步参数编辑器 + 截屏点选坐标 + 识图模板框选（2026-10-18）。
//

import SwiftUI

// MARK: - 单步编辑器

struct ScriptStepEditorView: View {

    @Binding var step: ScriptStep

    @State private var pickTarget: CoordinateTarget?
    @State private var showTemplateCrop = false
    @State private var templatePreview: UIImage?
    @State private var testMessage: String?
    @State private var isTesting = false

    var body: some View {
        Form {
            Section {
                Toggle("启用此步骤", isOn: $step.enabled)
                HStack {
                    Text("类型")
                    Spacer()
                    Text(step.type.title).foregroundColor(Theme.secondaryText)
                }
            }

            switch step.type {
            case .tap:
                coordinateSection(points: 1)
            case .longPress:
                coordinateSection(points: 1)
                durationSection(title: "长按时长（毫秒）", range: 100...5000)

            case .swipe:
                coordinateSection(points: 2)
                durationSection(title: "滑动时长（毫秒）", range: 50...5000)

            case .key:
                keySection

            case .text:
                textSection

            case .wait:
                waitSection

            case .shell:
                shellSection

            case .imageTap:
                imageSection
            }
        }
        .navigationTitle(step.type.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $pickTarget) { target in
            CoordinatePickerView { point in
                switch target {
                case .start:
                    step.x1 = point.x
                    step.y1 = point.y
                case .end:
                    step.x2 = point.x
                    step.y2 = point.y
                }
            }
        }
        .sheet(isPresented: $showTemplateCrop) {
            TemplateCropView { image, sourceWidth in
                if let file = ScriptManager.shared.storeTemplate(image: image) {
                    // 先删旧模板，避免留下孤儿文件
                    if let old = step.templateFile {
                        ScriptManager.shared.deleteTemplate(named: old)
                    }
                    step.templateFile = file
                    step.templateRefWidth = sourceWidth
                    templatePreview = image
                }
            }
        }
        .onAppear {
            if let file = step.templateFile {
                templatePreview = ScriptManager.shared.templateImage(named: file)
            }
        }
    }

    // MARK: - 坐标

    private enum CoordinateTarget: String, Identifiable {
        case start
        case end
        var id: String { rawValue }
    }

    @ViewBuilder
    private func coordinateSection(points: Int) -> some View {
        Section {
            HStack {
                Text("起点 X")
                Spacer()
                TextField("0-100", value: percent($step.x1), format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                Text("%").foregroundColor(Theme.secondaryText)
            }
            HStack {
                Text("起点 Y")
                Spacer()
                TextField("0-100", value: percent($step.y1), format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                Text("%").foregroundColor(Theme.secondaryText)
            }

            if points > 1 {
                HStack {
                    Text("终点 X")
                    Spacer()
                    TextField("0-100", value: percent($step.x2), format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                    Text("%").foregroundColor(Theme.secondaryText)
                }
                HStack {
                    Text("终点 Y")
                    Spacer()
                    TextField("0-100", value: percent($step.y2), format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                    Text("%").foregroundColor(Theme.secondaryText)
                }
            }

            Button {
                pickTarget = .start
            } label: {
                Label(points > 1 ? "截屏点选起点" : "截屏点选坐标", systemImage: "camera.viewfinder")
            }

            if points > 1 {
                Button {
                    pickTarget = .end
                } label: {
                    Label("截屏点选终点", systemImage: "camera.viewfinder")
                }
            }
        } header: {
            Text("坐标（屏幕百分比）")
        } footer: {
            Text("存的是百分比：换一台不同分辨率的手机，也会按同样比例点过去。")
        }
    }

    private func durationSection(title: String, range: ClosedRange<Int>) -> some View {
        Section {
            Stepper(value: $step.durationMs, in: range, step: 50) {
                HStack {
                    Text(title)
                    Spacer()
                    Text("\(step.durationMs)")
                        .foregroundColor(Theme.secondaryText)
                }
            }
        }
    }

    private func percent(_ binding: Binding<Double>) -> Binding<Double> {
        Binding(
            get: { (binding.wrappedValue * 1000).rounded() / 10 },
            set: { binding.wrappedValue = min(1, max(0, $0 / 100.0)) }
        )
    }

    // MARK: - 按键

    private var keySection: some View {
        Section {
            Picker("按键", selection: $step.keyCode) {
                ForEach(ScriptKeyCatalog.options) { option in
                    Text(option.name).tag(option.id)
                }
                if ScriptKeyCatalog.name(for: step.keyCode) == nil {
                    Text("自定义 \(step.keyCode)").tag(step.keyCode)
                }
            }

            HStack {
                Text("自定义键码")
                Spacer()
                TextField("keycode", value: $step.keyCode, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 100)
            }
        } header: {
            Text("按键")
        } footer: {
            Text("执行命令：adb shell input keyevent <键码>")
        }
    }

    // MARK: - 文字

    private var textSection: some View {
        Section {
            TextField("要输入的文字", text: $step.text)
                .autocapitalization(.none)
                .disableAutocorrection(true)
        } header: {
            Text("输入文字")
        } footer: {
            Text("目前只支持 ASCII（英文/数字/符号）；空格会自动转义成 %s。中文需要安装 ADBKeyboard，后续再加。")
        }
    }

    // MARK: - 等待

    private var waitSection: some View {
        Section {
            HStack {
                Text("等待（毫秒）")
                Spacer()
                TextField("1000", value: $step.waitMs, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 100)
            }
        } header: {
            Text("等待")
        }
    }

    // MARK: - Shell

    private var shellSection: some View {
        Section {
            TextEditor(text: $step.shell)
                .frame(minHeight: 130)
                .font(.system(.body, design: .monospaced))
                .autocapitalization(.none)
                .disableAutocorrection(true)
        } header: {
            Text("Shell 命令（原样执行）")
        } footer: {
            Text("例子：\ninput tap 540 1200\ninput swipe 540 1800 540 600 300\nam start -n com.android.settings/.Settings\n注意：命令会原样传给 adb shell，不会再做拆词。")
        }
    }

    // MARK: - 识图

    private var imageSection: some View {
        Section {
            if let preview = templatePreview {
                HStack {
                    Spacer()
                    Image(uiImage: preview)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 90)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.separator))
                    Spacer()
                }
            } else {
                Text("还没有模板图片")
                    .foregroundColor(Theme.secondaryText)
            }

            Button {
                showTemplateCrop = true
            } label: {
                Label(templatePreview == nil ? "截屏并框选模板" : "重新截屏框选", systemImage: "viewfinder")
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("匹配阈值")
                    Spacer()
                    Text(String(format: "%.2f", step.threshold))
                        .foregroundColor(Theme.secondaryText)
                }
                Slider(value: $step.threshold, in: 0.5...0.99, step: 0.01)
            }

            HStack {
                Text("找不到时等待")
                Spacer()
                TextField("5000", value: $step.matchTimeoutMs, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                Text("ms").foregroundColor(Theme.secondaryText)
            }

            Toggle("仅定位不点击（Dry run）", isOn: $step.dryRun)

            Button {
                runTestMatch()
            } label: {
                if isTesting {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("截屏匹配中…")
                    }
                } else {
                    Label("测试匹配", systemImage: "magnifyingglass")
                }
            }
            .disabled(isTesting)

            if let message = testMessage {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.secondaryText)
            }
        } header: {
            Text("识图点击")
        } footer: {
            Text("截取当前屏幕，在 App 内做模板匹配，找到后点击命中位置。跨分辨率靠多尺度匹配，命中率依赖模板是否稳定。")
        }
    }

    private func runTestMatch() {
        guard let file = step.templateFile,
              let template = ScriptManager.shared.templateImage(named: file) else {
            testMessage = "先截屏并框选模板"
            return
        }

        isTesting = true
        testMessage = "截屏中…"

        Task {
            guard let screen = await ScreenshotService.capture() else {
                isTesting = false
                testMessage = "截屏失败（页面可能受 FLAG_SECURE 保护）"
                return
            }
            let reference = step.templateRefWidth > 0
                ? CGFloat(step.templateRefWidth)
                : screen.size.width

            let match = TemplateMatcher.find(template: template,
                                             in: screen,
                                             referenceWidth: reference,
                                             threshold: 0.5)
            isTesting = false
            if let match {
                testMessage = String(format: "命中 score=%.3f，位置 (%.1f%%, %.1f%%)",
                                     match.score, match.center.x * 100, match.center.y * 100)
            } else {
                testMessage = String(format: "未命中（最高 %.3f）", TemplateMatcher.lastBestScore ?? 0)
            }
        }
    }
}

// MARK: - 截屏点选坐标

struct CoordinatePickerView: View {

    var onPick: (CGPoint) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var isLoading = true
    @State private var picked: CGPoint?
    @State private var errorText: String?

    var body: some View {
        NavigationView {
            GeometryReader { geometry in
                ZStack {
                    Color.black.opacity(0.92).ignoresSafeArea()

                    if let image {
                        let fitted = fittedRect(imageSize: image.size, in: geometry.size)

                        Image(uiImage: image)
                            .resizable()
                            .frame(width: fitted.width, height: fitted.height)
                            .offset(x: fitted.minX, y: fitted.minY)

                        Color.clear
                            .frame(width: fitted.width, height: fitted.height)
                            .offset(x: fitted.minX, y: fitted.minY)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onEnded { value in
                                        picked = CGPoint(
                                            x: min(1, max(0, value.location.x / fitted.width)),
                                            y: min(1, max(0, value.location.y / fitted.height))
                                        )
                                    }
                            )

                        if let point = picked {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 22, height: 22)
                                .overlay(Circle().stroke(Color.white, lineWidth: 2))
                                .offset(x: fitted.minX + point.x * fitted.width - 11,
                                        y: fitted.minY + point.y * fitted.height - 11)
                                .allowsHitTesting(false)
                        }
                    } else if isLoading {
                        ProgressView().tint(.white)
                    } else {
                        VStack(spacing: 12) {
                            Text(errorText ?? "截屏失败")
                                .foregroundColor(.white)
                            Button("重新截屏") {
                                Task { await capture() }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
            .navigationTitle("点选坐标")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("确认") {
                        if let point = picked {
                            onPick(point)
                            dismiss()
                        }
                    }
                    .disabled(picked == nil)
                }
            }
        }
        .task { await capture() }
    }

    private func capture() async {
        isLoading = true
        errorText = nil
        image = await ScreenshotService.capture()
        isLoading = false
        if image == nil {
            errorText = "截屏失败（页面可能受 FLAG_SECURE 保护）"
        }
    }
}

// MARK: - 截屏框选模板

struct TemplateCropView: View {

    /// (裁剪出的模板图, 截屏原始宽度)
    var onCrop: (UIImage, Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var selection: CGRect = .zero
    @State private var dragStart: CGPoint?
    @State private var containerSize: CGSize = .zero

    var body: some View {
        NavigationView {
            GeometryReader { geometry in
                ZStack {
                    Color.black.opacity(0.92).ignoresSafeArea()

                    if let image {
                        let fitted = fittedRect(imageSize: image.size, in: geometry.size)

                        Image(uiImage: image)
                            .resizable()
                            .frame(width: fitted.width, height: fitted.height)
                            .offset(x: fitted.minX, y: fitted.minY)

                        ZStack(alignment: .topLeading) {
                            Rectangle()
                                .fill(Color.green.opacity(0.12))
                                .frame(width: max(0, selection.width), height: max(0, selection.height))
                                .overlay(Rectangle().stroke(Color.green, lineWidth: 2))
                                .offset(x: selection.minX, y: selection.minY)
                        }
                        .frame(width: fitted.width, height: fitted.height)
                        .offset(x: fitted.minX, y: fitted.minY)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 6)
                                .onChanged { value in
                                    if dragStart == nil { dragStart = value.startLocation }
                                    let start = dragStart ?? value.startLocation
                                    selection = CGRect(
                                        x: min(start.x, value.location.x),
                                        y: min(start.y, value.location.y),
                                        width: abs(value.location.x - start.x),
                                        height: abs(value.location.y - start.y)
                                    )
                                }
                                .onEnded { _ in dragStart = nil }
                        )
                    } else if isLoading {
                        ProgressView().tint(.white)
                    } else {
                        VStack(spacing: 12) {
                            Text(errorText ?? "截屏失败")
                                .foregroundColor(.white)
                            Button("重新截屏") {
                                Task { await capture() }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
                .onAppear { containerSize = geometry.size }
                .onChange(of: geometry.size) { newSize in containerSize = newSize }
            }
            .navigationTitle("框选模板")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("使用") {
                        guard let image, selection.width >= 6, selection.height >= 6 else { return }
                        if let cropped = crop(image: image) {
                            onCrop(cropped, image.cgImage?.width ?? Int(image.size.width))
                            dismiss()
                        }
                    }
                    .disabled(selection.width < 6 || selection.height < 6)
                }
            }
        }
        .task { await capture() }
    }

    private func capture() async {
        isLoading = true
        errorText = nil
        image = await ScreenshotService.capture()
        isLoading = false
        selection = .zero
        if image == nil {
            errorText = "截屏失败（页面可能受 FLAG_SECURE 保护）"
        }
    }

    private func crop(image: UIImage) -> UIImage? {
        guard let cg = image.cgImage else { return nil }

        let fitted = fittedRect(imageSize: image.size, in: containerSize)
        guard fitted.width > 1, fitted.height > 1 else { return nil }

        // selection 的坐标就是「显示区域内」的坐标（gesture 层与图片同尺寸同位置）
        let nx = min(1, max(0, selection.minX / fitted.width))
        let ny = min(1, max(0, selection.minY / fitted.height))
        let nw = min(1 - nx, max(0, selection.width / fitted.width))
        let nh = min(1 - ny, max(0, selection.height / fitted.height))

        let rect = CGRect(x: nx * CGFloat(cg.width),
                          y: ny * CGFloat(cg.height),
                          width: nw * CGFloat(cg.width),
                          height: nh * CGFloat(cg.height)).integral

        guard rect.width >= 4, rect.height >= 4,
              let cropped = cg.cropping(to: rect) else {
            return nil
        }
        return UIImage(cgImage: cropped, scale: 1, orientation: .up)
    }
}

// MARK: - 工具

/// 计算 aspectFit 后图片在容器里的矩形
private func fittedRect(imageSize: CGSize, in container: CGSize) -> CGRect {
    guard imageSize.width > 0, imageSize.height > 0,
          container.width > 0, container.height > 0 else {
        return .zero
    }
    let scale = min(container.width / imageSize.width, container.height / imageSize.height)
    let width = imageSize.width * scale
    let height = imageSize.height * scale
    return CGRect(x: (container.width - width) / 2,
                  y: (container.height - height) / 2,
                  width: width,
                  height: height)
}

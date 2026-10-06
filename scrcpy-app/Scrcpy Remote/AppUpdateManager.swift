//
//  AppUpdateManager.swift
//  Scrcpy Remote
//
//  启动 / 回前台时检查有没有新构建；有就弹提示，「立即更新」直接唤起
//  TrollStore 装新版（apple-magnifier://install），全程在手机上完成，不需要电脑。
//
//  服务端：CI（build-ipa.yml）每次 main 构建都会覆盖 tag 为 latest-ipa 的
//  Release，并向其中上传：
//    - ScrcpyRemote-unsigned.ipa   （不签名包，TrollStore 直接装）
//    - latest.json                 （{"build","ipa","ipa_cn","date"}）
//  App 的构建号（CFBundleVersion）由 CI 注入为「CI 运行号」，和 latest.json 的 build 字段一对比就知道有没有新版。
//
//  大陆网络对 GitHub 不稳，所以做了双通道：
//    - 清单（latest.json）：先 GitHub，失败换家里镜像 https://home.szafx.icu:8898/
//    - IPA 下载：优先探活家里镜像（快），不可达回退 GitHub
//  家里镜像由家里那台机器定时从 Release 同步（见项目文档）。
//
//  ★ 弹窗时序（2026-10-07 用户反馈后重做）：
//    发现的新版本会**持久化**。只要「还没装上」且没点过「稍后」：
//    **每次 App 打开 / 回前台都会再弹**（这一步不需要网络，也不受检查节流影响）。
//    网络刷新（拉最新清单）另按 1 小时节流在后台跑。
//    这样「点更新 → 跳 TrollStore → 不装直接返回」会再次看到提示，直到装掉或点稍后。
//

import Foundation
import UIKit

class AppUpdateManager: ObservableObject {
    static let shared = AppUpdateManager()

    // ★ 固定地址（CI 覆盖式更新，URL 永不变）
    private static let manifestURLs: [URL] = [
        URL(string: "https://github.com/szafx/scrcpy-mobile/releases/download/latest-ipa/latest.json")!,
        URL(string: "https://home.szafx.icu:8898/latest.json")!,   // 家里镜像（大陆直连）
    ]
    private static let installSchemePrefix = "apple-magnifier://install?url="

    private static let dismissedBuildKey = "AppUpdateManager.dismissedBuild"
    private static let lastCheckAtKey = "AppUpdateManager.lastCheckAt"
    private static let minCheckInterval: TimeInterval = 3600   // 网络刷新最少隔 1 小时

    // 已知可用版本（持久化）—— 弹提示用，不依赖网络
    private static let pendingBuildKey = "AppUpdateManager.pendingBuild"
    private static let pendingIPAGitHubKey = "AppUpdateManager.pendingIPAGithub"
    private static let pendingIPACNKey = "AppUpdateManager.pendingIPACN"

    @Published var shouldShowUpdateAlert = false
    @Published private(set) var availableBuild = ""

    private var availableIPAGitHub: URL?
    private var availableIPACN: URL?

    private struct Manifest: Decodable {
        let build: String
        let ipa: String
        let ipa_cn: String?
    }

    /// 检查更新。onAppear / didBecomeActive 都会调。
    func checkForUpdate(force: Bool = false) {
        // ① 先把「已知的新版本」弹出来 —— 这一步不需要网络、不受节流限制。
        //    点更新跳 TrollStore 又没装就退回来？下次回前台还会再弹。
        presentPendingIfNeeded()

        // ② 再按节流去拉最新清单（顺带把 pending 更新为最新）
        let now = Date().timeIntervalSince1970
        let last = UserDefaults.standard.double(forKey: Self.lastCheckAtKey)
        guard force || now - last >= Self.minCheckInterval else { return }
        UserDefaults.standard.set(now, forKey: Self.lastCheckAtKey)
        fetchManifest(from: 0)
    }

    /// 用 TrollStore 的 scheme 直接装新版（TrollStore 会自己下载 IPA）。
    /// 先探活家里镜像源（大陆快），不可用则回退 GitHub。
    func updateNow() {
        guard let github = availableIPAGitHub else {
            print("🔄 [AppUpdate] 更新链接无效")
            return
        }
        if let cn = availableIPACN {
            probeReachable(cn) { [weak self] ok in
                guard let self else { return }
                if ok {
                    print("🔄 [AppUpdate] 家里镜像源可达，使用国内通道")
                    self.openInTrollStore(cn)
                } else {
                    print("🔄 [AppUpdate] 家里镜像源不可达，回退 GitHub")
                    self.openInTrollStore(github)
                }
            }
        } else {
            openInTrollStore(github)
        }
    }

    /// 「稍后」：记住这个构建不再弹（下一个新构建会再弹）。
    func dismiss() {
        if !availableBuild.isEmpty {
            UserDefaults.standard.set(availableBuild, forKey: Self.dismissedBuildKey)
        }
        shouldShowUpdateAlert = false
    }

    // MARK: - private

    /// 已发现但还没装的新版本 —— 每次回前台都弹（除非已装 / 已点稍后）。
    private func presentPendingIfNeeded() {
        let defaults = UserDefaults.standard
        guard let pending = defaults.string(forKey: Self.pendingBuildKey), !pending.isEmpty else { return }

        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        if pending == current {
            // 已经装上了 —— 清掉记录
            clearPending()
            return
        }
        if defaults.string(forKey: Self.dismissedBuildKey) == pending {
            return   // 用户点过「稍后」
        }
        if shouldShowUpdateAlert, availableBuild == pending { return }   // 正在弹，别重复

        availableBuild = pending
        availableIPAGitHub = (defaults.string(forKey: Self.pendingIPAGitHubKey)).flatMap { URL(string: $0) }
        if let cn = defaults.string(forKey: Self.pendingIPACNKey), !cn.isEmpty {
            availableIPACN = URL(string: cn)
        }
        guard availableIPAGitHub != nil else { return }
        print("🔄 [AppUpdate] 提醒：新构建 \(pending) 尚未安装")
        shouldShowUpdateAlert = true
    }

    private func clearPending() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.pendingBuildKey)
        defaults.removeObject(forKey: Self.pendingIPAGitHubKey)
        defaults.removeObject(forKey: Self.pendingIPACNKey)
    }

    /// 依次尝试各个清单源（GitHub → 家里镜像）。
    private func fetchManifest(from index: Int) {
        guard index < Self.manifestURLs.count else {
            print("🔄 [AppUpdate] 所有清单源都不可用")
            return
        }
        var request = URLRequest(url: Self.manifestURLs[index])
        request.timeoutInterval = 15
        // Release 资源会被 CDN 缓存，不看缓存头可能拿到旧的清单
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self else { return }
            guard let data, error == nil,
                  let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
                print("🔄 [AppUpdate] 清单源 \(index) 不可用（\(error?.localizedDescription ?? "解析失败")），试下一个")
                self.fetchManifest(from: index + 1)
                return
            }
            self.handle(manifest)
        }.resume()
    }

    private func handle(_ manifest: Manifest) {
        let defaults = UserDefaults.standard
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""

        guard !manifest.build.isEmpty, manifest.build != current else {
            // 已是最新 —— 清掉残留的 pending 记录
            print("🔄 [AppUpdate] 已是最新（\(current)）")
            clearPending()
            return
        }
        guard defaults.string(forKey: Self.dismissedBuildKey) != manifest.build else {
            print("🔄 [AppUpdate] 新构建 \(manifest.build) 已被跳过，不重复提示")
            return
        }

        print("🔄 [AppUpdate] 发现新构建：\(current) -> \(manifest.build)")
        DispatchQueue.main.async {
            // 持久化：下次冷启动/回前台靠它弹窗（不依赖网络）
            defaults.set(manifest.build, forKey: Self.pendingBuildKey)
            defaults.set(manifest.ipa, forKey: Self.pendingIPAGitHubKey)
            if let cn = manifest.ipa_cn {
                defaults.set(cn, forKey: Self.pendingIPACNKey)
            }
            self.presentPendingIfNeeded()
        }
    }

    /// 快速 HEAD 探活（3 秒超时，失败就当不可达）。
    private func probeReachable(_ url: URL, completion: @escaping (Bool) -> Void) {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 3
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        URLSession.shared.dataTask(with: request) { _, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let ok = error == nil && (200..<400).contains(code)
            completion(ok)
        }.resume()
    }

    private func openInTrollStore(_ ipa: URL) {
        // ★ 只做「最小编码」：URL 放在 url= 参数里时，只需转义会截断查询串的
        //   字符（空格/&/?/#/+）。整串百分号编码（.alphanumerics）实测会让
        //   TrollStore 报错拒收（2026-10-07：镜像日志只有 HEAD 探活、没有下载请求，
        //   说明它拿到 URL 就没开始下）。最小编码对两种解析器都兼容。
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=?#+")
        guard let encoded = ipa.absoluteString.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: Self.installSchemePrefix + encoded) else {
            print("🔄 [AppUpdate] 更新链接编码失败")
            return
        }
        print("🔄 [AppUpdate] 唤起 TrollStore 安装：\(url.absoluteString)")
        DispatchQueue.main.async {
            UIApplication.shared.open(url)
        }
    }
}

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
//    - 清单（latest.json）：先 GitHub，失败换家里镜像 http://home.szafx.icu:8898/
//    - IPA 下载：优先探活家里镜像（快），不可达回退 GitHub
//  家里镜像由家里那台机器定时从 Release 同步（见项目文档）。
//

import Foundation
import UIKit

class AppUpdateManager: ObservableObject {
    static let shared = AppUpdateManager()

    // ★ 固定地址（CI 覆盖式更新，URL 永不变）
    private static let manifestURLs: [URL] = [
        URL(string: "https://github.com/szafx/scrcpy-mobile/releases/download/latest-ipa/latest.json")!,
        URL(string: "http://home.szafx.icu:8898/latest.json")!,   // 家里镜像（大陆直连）
    ]
    private static let installSchemePrefix = "apple-magnifier://install?url="

    private static let dismissedBuildKey = "AppUpdateManager.dismissedBuild"
    private static let lastCheckAtKey = "AppUpdateManager.lastCheckAt"
    private static let minCheckInterval: TimeInterval = 3600   // 最少隔 1 小时才再查一次

    @Published var shouldShowUpdateAlert = false
    @Published private(set) var availableBuild = ""

    private var availableIPAGitHub: URL?
    private var availableIPACN: URL?

    private struct Manifest: Decodable {
        let build: String
        let ipa: String
        let ipa_cn: String?
    }

    /// 检查更新。onAppear / didBecomeActive 都会调，内部有节流。
    func checkForUpdate(force: Bool = false) {
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
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        guard !manifest.build.isEmpty, manifest.build != current else {
            print("🔄 [AppUpdate] 已是最新（\(current)）")
            return
        }
        guard UserDefaults.standard.string(forKey: Self.dismissedBuildKey) != manifest.build else {
            print("🔄 [AppUpdate] 新构建 \(manifest.build) 已被跳过，不重复提示")
            return
        }
        print("🔄 [AppUpdate] 发现新构建：\(current) -> \(manifest.build)")
        DispatchQueue.main.async {
            self.availableBuild = manifest.build
            self.availableIPAGitHub = URL(string: manifest.ipa)
            if let cn = manifest.ipa_cn {
                self.availableIPACN = URL(string: cn)
            }
            self.shouldShowUpdateAlert = true
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
        guard let encoded = ipa.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let url = URL(string: Self.installSchemePrefix + encoded) else {
            print("🔄 [AppUpdate] 更新链接编码失败")
            return
        }
        print("🔄 [AppUpdate] 唤起 TrollStore 安装：\(ipa.absoluteString)")
        DispatchQueue.main.async {
            UIApplication.shared.open(url)
        }
    }
}

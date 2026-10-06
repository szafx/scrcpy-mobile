//
//  DeviceDiscovery.swift
//  Scrcpy Remote
//
//  「发现设备」的统一数据源（Devices 页的扫描面板用）：
//    · 局域网组：扫网段 → 批量识别（型号 + 序列号后4位）→ 认完立即断开
//    · frpc 在线组：拉 frps 管理接口（webServer）的在线 proxy 名单
//    · 合并：同一台（型号 + 序列号后4位相同）两边都出现时合成一行，
//      连接时由既有的三级连接逻辑自动「局域网 → frpc(P2P) → 中转」选路。
//
//  ★ 识别读的是 ro.serialno / ro.product.model，和被控端部署脚本
//    （deploy-frpc.py 的 phone-<型号>-<序列号后4位>）同源，所以两边能对上。
//
//  ★ 速度设计（2026-10-07 用户反馈"局域网好慢"后重做）：
//    ① 身份结果**持久缓存**（host → 型号+后缀）—— 识别过的设备下次秒出
//    ② 未识别的设备：**并行发起 adb connect**（握手最慢，并发摊掉），
//       等状态沉淀（offline/authorizing → device）后**串行读身份**（此时很快）
//    ③ 型号和序列号一次 shell 全拿（`getprop A; getprop B`），省一半往返
//

import Foundation

struct DiscoveredDevice: Identifiable {
    let id: String              // "<型号>-<序列号后4位>"，如 COR-AL10-1911
    let model: String           // COR-AL10
    let suffix: String          // 1911
    var lanHost: String?        // 局域网地址（nil = 不在局域网）
    var frpProxyName: String?   // frpc 在线时的 proxy 名（nil = 没挂 frpc）

    var displayName: String { "\(model) · \(suffix)" }
    var canLan: Bool { lanHost != nil }
    var canFrp: Bool { frpProxyName != nil }
}

@MainActor
final class DeviceDiscovery: ObservableObject {

    @Published var devices: [DiscoveredDevice] = []
    @Published var phase: String = ""
    @Published var frpError: String? = nil
    @Published private(set) var running = false

    /// 跑一轮完整发现：先 frpc 名单（快），再局域网扫描 + 批量识别（逐台出现）。
    func run() async {
        running = true
        devices = []
        frpError = nil

        phase = "Getting frpc online devices…"
        let (frpDevices, frpErr) = await Self.fetchFrpOnline()
        frpError = frpErr
        merge(frpDevices)

        phase = "Scanning LAN…"
        let candidates = await LanDiscovery.discover()

        // ① 命中过的设备先用缓存**立即上屏**（识别结果几乎不变：序列号不会变）
        let cache = Self.loadIdentityCache()
        var needIdentify: [String] = []
        for candidate in candidates {
            if let cached = cache[candidate.host] {
                merge([DiscoveredDevice(id: "\(cached.0)-\(cached.1)",
                                        model: cached.0,
                                        suffix: cached.1,
                                        lanHost: candidate.host,
                                        frpProxyName: nil)])
            } else {
                needIdentify.append(candidate.host)
            }
        }

        // ② 没缓存过的批量识别（并行握手 + 串行读身份）
        if !needIdentify.isEmpty {
            phase = "Identifying devices…"
            let identified = await Self.identifyMany(hosts: needIdentify)
            var newCache = cache
            for (host, info) in identified {
                newCache[host] = (info.model, info.suffix)
                merge([DiscoveredDevice(id: "\(info.model)-\(info.suffix)",
                                        model: info.model,
                                        suffix: info.suffix,
                                        lanHost: host,
                                        frpProxyName: nil)])
            }
            Self.saveIdentityCache(newCache)
        }

        phase = devices.isEmpty ? "No devices found" : "Done"
        running = false
    }

    // MARK: - 合并

    private func merge(_ incoming: [DiscoveredDevice]) {
        for device in incoming {
            if let index = devices.firstIndex(where: { $0.id == device.id }) {
                if let lan = device.lanHost { devices[index].lanHost = lan }
                if let frp = device.frpProxyName { devices[index].frpProxyName = frp }
            } else {
                devices.append(device)
            }
        }
    }

    // MARK: - 身份缓存（host -> 型号、序列号后4位）

    private static let identityCacheKey = "settings.discovery.lan_identity_cache"

    private static func loadIdentityCache() -> [String: (String, String)] {
        guard let raw = UserDefaults.standard.dictionary(forKey: identityCacheKey) as? [String: [String]] else {
            return [:]
        }
        var out: [String: (String, String)] = [:]
        for (host, pair) in raw where pair.count == 2 {
            out[host] = (pair[0], pair[1])
        }
        return out
    }

    private static func saveIdentityCache(_ cache: [String: (String, String)]) {
        var raw: [String: [String]] = [:]
        for (host, pair) in cache {
            raw[host] = [pair.0, pair.1]
        }
        UserDefaults.standard.set(raw, forKey: identityCacheKey)
    }

    // MARK: - 批量识别

    /// 对一批 host 做识别：并行 connect → 等状态沉淀 → 串行读身份 → 全部断开。
    /// 返回 host -> (model, suffix)。
    private static func identifyMany(hosts: [String]) async -> [String: (model: String, suffix: String)] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let client = ADBClient.shared()
                func target(_ host: String) -> String { "\(host):5555" }

                // ① 并行发起 connect —— 每次握手动辄一两秒，串行是慢的主因
                let group = DispatchGroup()
                for host in hosts {
                    group.enter()
                    DispatchQueue.global(qos: .utility).async {
                        _ = client.executeADBCommand(["connect", target(host)], returnCode: nil)
                        group.leave()
                    }
                }
                _ = group.wait(timeout: .now() + 12)

                // ② 等状态沉淀：offline/authorizing 的等它变 device（最多 8 秒）
                let deadline = Date().addingTimeInterval(8)
                while Date() < deadline {
                    let states = parseDeviceStates(client.executeADBCommand(["devices"], returnCode: nil))
                    let pending = hosts.contains { host in
                        let state = states[target(host)]
                        return state == nil || state == "offline"
                            || state == "connecting" || state == "authorizing"
                    }
                    if !pending { break }
                    Thread.sleep(forTimeInterval: 0.3)
                }

                // ③ 串行读身份（transport 已就绪，快）；型号+序列号一次拿
                var result: [String: (model: String, suffix: String)] = [:]
                for host in hosts {
                    let t = target(host)
                    var rc: Int32 = 0
                    let output = client.executeADBCommand(
                        ["-s", t, "shell", "getprop ro.serialno; getprop ro.product.model"],
                        returnCode: &rc
                    )
                    let lines = output.split(separator: "\n")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    if rc == 0, lines.count >= 2 {
                        let serial = lines[0]
                        let model = lines[1]
                        if serial.count >= 4, !model.isEmpty {
                            result[host] = (model, String(serial.suffix(4)))
                            print("[DeviceDiscovery] \(host) -> \(model)-\(serial.suffix(4))")
                        }
                    }
                    // 认完人就撤 —— 设备表保洁第一道防线（别留临时连接炸 push）
                    _ = client.executeADBCommand(["disconnect", t], returnCode: nil)
                }

                continuation.resume(returning: result)
            }
        }
    }

    /// 解析 `adb devices` 输出：addr -> state
    private static func parseDeviceStates(_ output: String) -> [String: String] {
        var states: [String: String] = [:]
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("List of devices") { continue }
            let parts = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 2 else { continue }
            states[parts[0]] = parts[1]
        }
        return states
    }

    // MARK: - frps 在线名单

    /// 返回（发现的设备, 错误说明）。纯数据进出，错误由调用方贴到界面上。
    private static func fetchFrpOnline() async -> ([DiscoveredDevice], String?) {
        let settings = FrpSettings.load()
        guard !settings.serverAddr.isEmpty else {
            return ([], "frps not configured")
        }
        guard !settings.adminUser.isEmpty, !settings.adminPass.isEmpty else {
            return ([], "need frps admin account")
        }

        guard let url = URL(string: "http://\(settings.serverAddr):\(settings.adminPort)/api/proxy/xtcp") else {
            return ([], "bad frps address")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let credential = Data("\(settings.adminUser):\(settings.adminPass)".utf8).base64EncodedString()
        request.setValue("Basic \(credential)", forHTTPHeaderField: "Authorization")

        let json: [String: Any]? = await withCheckedContinuation { continuation in
            URLSession.shared.dataTask(with: request) { data, _, error in
                guard let data, error == nil,
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: object)
            }.resume()
        }

        guard let json, let proxies = json["proxies"] as? [[String: Any]] else {
            return ([], "frps admin unreachable")
        }

        var found: [DiscoveredDevice] = []
        for proxy in proxies {
            guard let name = proxy["name"] as? String,
                  name.hasPrefix("phone-"), !name.hasSuffix("-tcp") else { continue }
            let parts = name.split(separator: "-").map(String.init)
            guard parts.count >= 3 else { continue }
            let suffix = parts[parts.count - 1]
            let model = parts[1..<(parts.count - 1)].joined(separator: "-")
            found.append(DiscoveredDevice(id: "\(model)-\(suffix)",
                                          model: model,
                                          suffix: suffix,
                                          lanHost: nil,
                                          frpProxyName: name))
        }
        return (found, nil)
    }
}

//
//  DeviceDiscovery.swift
//  Scrcpy Remote
//
//  「发现设备」的统一数据源（Devices 页的扫描面板用）：
//    · 局域网组：扫网段 → 逐台 adb 认序列号/型号 → 认完立即断开
//    · frpc 在线组：拉 frps 管理接口（webServer）的在线 proxy 名单
//    · 合并：同一台（型号 + 序列号后4位相同）两边都出现时合成一行，
//      连接时由既有的三级连接逻辑自动「局域网 → frpc(P2P) → 中转」选路。
//
//  ★ 认设备读的是 ro.serialno / ro.product.model，和被控端部署脚本
//    （deploy-frpc.py 的 phone-<型号>-<序列号后4位>）同源，所以两边能对上。
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

    /// 跑一轮完整发现：先 frpc 名单（快），再局域网扫描 + 逐台识别（慢，逐台出现）。
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
        if candidates.isEmpty {
            phase = devices.isEmpty ? "No devices found" : "Done"
            running = false
            return
        }

        for candidate in candidates {
            phase = "Identifying devices…"
            if let info = await Self.identify(host: candidate.host) {
                merge([DiscoveredDevice(id: "\(info.model)-\(info.suffix)",
                                        model: info.model,
                                        suffix: info.suffix,
                                        lanHost: candidate.host,
                                        frpProxyName: nil)])
            }
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

    // MARK: - 局域网识别

    /// adb 连上去读型号 + 序列号后4位，读完**立即断开**（不污染设备表）。
    private static func identify(host: String) async -> (model: String, suffix: String)? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let target = "\(host):5555"
                let client = ADBClient.shared()
                _ = client.executeADBCommand(["connect", target], returnCode: nil)

                var rc: Int32 = 0
                let serial = client.executeADBCommand(
                    ["-s", target, "shell", "getprop", "ro.serialno"],
                    returnCode: &rc
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                let model = client.executeADBCommand(
                    ["-s", target, "shell", "getprop", "ro.product.model"],
                    returnCode: nil
                ).trimmingCharacters(in: .whitespacesAndNewlines)

                // 认完人就撤 —— 这是设备表保洁的第一道防线（2000 字注释见
                // SessionNetworking.readSerialNumber：留着会炸 push）
                _ = client.executeADBCommand(["disconnect", target], returnCode: nil)

                if rc == 0, !serial.isEmpty, !model.isEmpty, serial.count >= 4 {
                    let suffix = String(serial.suffix(4))
                    print("[DeviceDiscovery] \(host) -> \(model)-\(suffix)")
                    continuation.resume(returning: (model, suffix))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
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

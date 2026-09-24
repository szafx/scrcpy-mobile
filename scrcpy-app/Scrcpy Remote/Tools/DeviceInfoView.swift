//
//  DeviceInfoView.swift
//  Scrcpy Remote
//
//  Console → Device info：OS / CPU / 内存 / 存储 / 电池 / 显示。
//
//  全部走纯 `adb shell`，不需要任何设备端服务端。
//  一次性拿完 —— 每次 adb 调用都要起一个进程 + 一个 shell，能合并就合并
//  （用 `echo '#XX'` 做分隔符，这个手法本仓库已经在别处用过）。
//
//  电池那套判据（status 码 2/3/4/5、temperature 是** tenths of a degree**）
//  是从 Windows 端 `手机投屏.exe` 的实现里搬过来的，实测过。
//

import SwiftUI

struct DeviceInfoView: View {

    @State private var isLoading = false
    @State private var errorText: String?
    @State private var fields: [String: String] = [:]
    @State private var battery: BatteryInfo?
    @State private var storageRows: [StorageRow] = []
    @State private var lastUpdated: Date?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {

                if let errorText = errorText {
                    CardContainer {
                        Label(errorText, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(Theme.warnForeground)
                    }
                }

                if isLoading && fields.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Reading device info…")
                            .foregroundColor(Theme.secondaryText)
                    }
                    .padding(.vertical, 30)
                    .frame(maxWidth: .infinity)
                }

                if !fields.isEmpty {
                    section("Device") {
                        row("Model", fields["MODEL"])
                        row("Brand", fields["BRAND"])
                        row("Android", fields["REL"].map { "\($0)  (API \(fields["SDK"] ?? "?"))" })
                        row("ABI", fields["ABI"])
                        row("Serial", fields["SERIAL"])
                    }

                    section("CPU") {
                        row("SoC", fields["SOC"] ?? fields["HARDWARE"])
                        row("Cores", fields["NPROC"])
                        row("Hardware", fields["HARDWARE"])
                    }

                    section("Memory") {
                        row("Total", fields["MEMTOTAL"].flatMap { Int64($0) }.map(AdbToolService.formatBytes))
                        row("Available", fields["MEMAVAIL"].flatMap { Int64($0) }.map(AdbToolService.formatBytes))
                    }

                    if let battery = battery {
                        section("Battery") {
                            HStack {
                                Text("Level")
                                    .font(.system(size: 14))
                                    .foregroundColor(Theme.secondaryText)
                                Spacer()
                                Text(battery.levelText)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(battery.levelColor)
                            }
                            row("Temperature", battery.temperatureText, valueColor: battery.temperatureColor)
                            row("Status", battery.statusText)
                            row("Health", battery.healthText, valueColor: battery.healthIsGood ? nil : Theme.dangerForeground)
                        }
                    }

                    if !storageRows.isEmpty {
                        section("Storage") {
                            ForEach(storageRows) { item in
                                row(item.label, item.value)
                            }
                        }
                    }

                    section("Display") {
                        row("Size", fields["WMSIZE"])
                        row("Density", fields["WMDENS"])
                    }
                }

                if let lastUpdated = lastUpdated {
                    Text("Updated \(Self.timeFormatter.string(from: lastUpdated))")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.secondaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.vertical, 12)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationBarTitle("Device info", displayMode: .inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    load()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
        }
        .onAppear { if fields.isEmpty { load() } }
    }

    // MARK: - 版式

    @ViewBuilder
    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.secondaryText)
            CardContainer {
                VStack(alignment: .leading, spacing: 10) {
                    content()
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ label: LocalizedStringKey, _ value: String?, valueColor: Color? = nil) -> some View {
        if let value = value, !value.isEmpty {
            HStack(alignment: .top) {
                Text(label)
                    .font(.system(size: 14))
                    .foregroundColor(Theme.secondaryText)
                Spacer(minLength: 12)
                // 值多半是动态的（电量、温度、容量），查不到表就回落成原文；
                // 但 Status/Health 那种固定词（Charging / Full / Good）就能翻出来。
                Text(LocalizedStringKey(value))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(valueColor ?? .primary)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    // MARK: - 取数

    private func load() {
        guard !isLoading else { return }
        isLoading = true
        errorText = nil

        Task {
            let service = AdbToolService.shared
            guard service.isReady else {
                await MainActor.run {
                    errorText = service.notReadyReason
                    isLoading = false
                }
                return
            }

            let dump = await service.shell(Self.probeCommand)

            await MainActor.run {
                isLoading = false
                lastUpdated = Date()

                guard dump.ok || !dump.trimmed.isEmpty else {
                    errorText = "Command failed: \(dump.trimmed.isEmpty ? "no output" : dump.trimmed)"
                    return
                }

                let parsed = Self.parseSections(dump.output)
                fields = parsed.values

                if let total = parsed.memTotal, let avail = parsed.memAvailable {
                    fields["MEMTOTAL"] = total
                    fields["MEMAVAIL"] = avail
                }

                battery = BatteryInfo(raw: parsed.battery)
                storageRows = parsed.storage
            }
        }
    }

    /// 一次 adb 调用把所有东西拿回来。`echo '#XX'` 是分隔标记。
    private static let probeCommand: String = [
        "echo '#MODEL'",     "getprop ro.product.model",
        "echo '#BRAND'",     "getprop ro.product.brand",
        "echo '#REL'",       "getprop ro.build.version.release",
        "echo '#SDK'",       "getprop ro.build.version.sdk",
        "echo '#SERIAL'",    "getprop ro.serialno",
        "echo '#SOC'",       "getprop ro.soc.model",
        "echo '#HARDWARE'",  "getprop ro.hardware",
        "echo '#ABI'",       "getprop ro.product.cpu.abi",
        "echo '#NPROC'",     "nproc",
        "echo '#MEM'",       "grep -E 'MemTotal|MemAvailable' /proc/meminfo",
        "echo '#DFEMU'",     "df -h /storage/emulated | tail -1",
        "echo '#DFROOT'",    "df -h / | tail -1",
        "echo '#WMSIZE'",    "wm size",
        "echo '#WMDENS'",    "wm density",
        "echo '#BATT'",      "dumpsys battery | grep -E 'level:|temperature:|status:|health:|voltage:'",
    ].joined(separator: "; ")

    private struct Parsed {
        var values: [String: String] = [:]
        var memTotal: String?
        var memAvailable: String?
        var battery: [String: String] = [:]
        var storage: [StorageRow] = []
    }

    private static func parseSections(_ output: String) -> Parsed {
        var result = Parsed()
        var current: String?

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if line.hasPrefix("#") {
                current = String(line.dropFirst())
                continue
            }
            guard let section = current, !line.isEmpty else { continue }

            switch section {
            case "MODEL", "BRAND", "REL", "SDK", "SERIAL", "SOC", "HARDWARE", "ABI", "NPROC":
                // 同一个 key 只取第一行有效值
                if result.values[section] == nil { result.values[section] = line }

            case "MEM":
                if line.contains("MemTotal") {
                    result.memTotal = firstNumber(in: line, unit: "kB")
                } else if line.contains("MemAvailable") {
                    result.memAvailable = firstNumber(in: line, unit: "kB")
                }

            case "DFEMU":
                result.storage.append(StorageRow(label: "Internal", value: describeDf(line)))

            case "DFROOT":
                result.storage.append(StorageRow(label: "System", value: describeDf(line)))

            case "WMSIZE":
                if result.values["WMSIZE"] == nil {
                    // 可能是 "Physical size: 1080x2408"，也可能多一行 "Override size: ..."
                    result.values["WMSIZE"] = line.replacingOccurrences(of: "Physical size: ", with: "")
                } else if line.hasPrefix("Override") {
                    result.values["WMSIZE"] = line.replacingOccurrences(of: "Override size: ", with: "") + " (override)"
                }

            case "WMDENS":
                if result.values["WMDENS"] == nil {
                    result.values["WMDENS"] = line.replacingOccurrences(of: "Physical density: ", with: "")
                } else if line.hasPrefix("Override") {
                    result.values["WMDENS"] = line.replacingOccurrences(of: "Override density: ", with: "") + " (override)"
                }

            case "BATT":
                if let colon = line.firstIndex(of: ":") {
                    let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
                    let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    result.battery[key] = value
                }

            default:
                break
            }
        }

        return result
    }

    /// `MemTotal:  7594400 kB` → `7594400`（并换算成字节）
    private static func firstNumber(in line: String, unit: String) -> String? {
        let parts = line.split(separator: " ").map(String.init)
        guard parts.count >= 2 else { return nil }
        // 最后一段是单位
        guard let value = Int64(parts[parts.count - 2]) else { return nil }
        let isKilobytes = parts[parts.count - 1].lowercased() == unit.lowercased()
        return String(isKilobytes ? value * 1024 : value)
    }

    /// `df -h` 的一行：Filesystem Size Used Avail Use% Mounted
    private static func describeDf(_ line: String) -> String {
        let parts = line.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard parts.count >= 5 else { return line }
        let size = parts[parts.count - 5]
        let used = parts[parts.count - 4]
        let avail = parts[parts.count - 3]
        let percent = parts[parts.count - 2]
        return "\(used) / \(size)  ·  \(avail) free  (\(percent))"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

// MARK: - 存储行

struct StorageRow: Identifiable {
    let id = UUID()
    let label: LocalizedStringKey
    let value: String
}

// MARK: - 电池

struct BatteryInfo {
    let level: Int?
    let temperatureCelsius: Double?
    let status: Int?
    let health: Int?

    init(raw: [String: String]) {
        level = raw["level"].flatMap { Int($0) }
        // ★ temperature 是**十分之一摄氏度**：280 = 28.0°C
        temperatureCelsius = raw["temperature"].flatMap { Double($0) }.map { $0 / 10.0 }
        status = raw["status"].flatMap { Int($0) }
        health = raw["health"].flatMap { Int($0) }
    }

    var levelText: String {
        guard let level = level else { return "—" }
        guard let status = status else { return "\(level)%" }
        switch status {
        // 这几个词是拼进字符串的，查表查不到整串，只能就地翻
        case 2: return "\(level)%  ⚡ " + NSLocalizedString("charging", comment: "")
        case 4: return "\(level)%  (" + NSLocalizedString("not charging", comment: "") + ")"
        case 5: return "\(level)%  (" + NSLocalizedString("full", comment: "") + ")"
        default: return "\(level)%"
        }
    }

    /// 电量低才算问题 —— 这台手机长期插电，满电不是告警。
    var levelColor: Color {
        guard let level = level else { return .primary }
        if level <= 15 { return Theme.dangerForeground }
        if level <= 30 { return Theme.warnForeground }
        return .primary
    }

    var temperatureText: String {
        guard let celsius = temperatureCelsius else { return "—" }
        return String(format: "%.1f °C", celsius)
    }

    /// 温度上色：<40 正常、≥40 橙、≥45 红。
    /// 这台手机没屏幕、又长期插 USB，温度是唯一能提前看出鼓包的指标。
    var temperatureColor: Color? {
        guard let celsius = temperatureCelsius else { return nil }
        if celsius >= 45 { return Theme.dangerForeground }
        if celsius >= 40 { return Theme.warnForeground }
        return nil
    }

    var statusText: String {
        switch status {
        case 1: return "Unknown"
        case 2: return "Charging"
        case 3: return "Discharging"
        case 4: return "Not charging"
        case 5: return "Full"
        default: return "—"
        }
    }

    var healthIsGood: Bool { health == 2 }

    var healthText: String {
        switch health {
        case 1: return "Unknown"
        case 2: return "Good"
        case 3: return "Overheat"
        case 4: return "Dead"
        case 5: return "Over voltage"
        case 6: return "Unspecified failure"
        case 7: return "Cold"
        default: return "—"
        }
    }
}

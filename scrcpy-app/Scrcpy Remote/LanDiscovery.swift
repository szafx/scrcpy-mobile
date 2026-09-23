//
//  LanDiscovery.swift
//  Scrcpy Remote
//
//  自动发现「同一局域网里的安卓手机」，不需要用户手填任何 IP。
//
//  为什么需要它：
//    手机在局域网里的地址是 DHCP 分的，会变 —— 让用户手填 IP 等于让他维护一份
//    随时会过期的表，那「优先走局域网」就成了假的。所以这里自己扫：
//    拿本机（iPhone）的 IP + 掩码算出网段，挨个探 adb 端口（默认 5555）。
//
//  实现取舍：
//    - 用 BSD socket 的**非阻塞 connect + select** 批量探，而不是 254 个 NWConnection。
//      iOS 上同时开几百个 NWConnection 资源吃紧，而裸 socket 只是发个 SYN，很轻。
//    - 分批发（默认 64 个一批），避免瞬间打爆。
//    - 只扫本机所在的 IPv4 网段；/24 以外的网段（比如 /16）会做个上限截断，
//      不然要扫 6 万多个地址。
//

import Foundation

struct LanDiscovery {

    /// iOS 上 WiFi 就是 en0（蜂窝是 pdp_ip*，VPN 是 utun*）。
    /// 只扫 WiFi —— 走移动数据时根本没有「同一个局域网」可言，硬扫只会拖慢连接。
    private static let wifiInterfaceName = "en0"

    /// 扫出来的候选地址（只含 adb 端口开放的主机）
    struct Candidate {
        let host: String
        let port: UInt16
    }

    /// 扫本机所在网段，返回所有 adb 端口开放的主机。
    ///
    /// - Parameters:
    ///   - port: adb 端口（默认 5555）
    ///   - timeout: 单个地址的连接超时（毫秒级就够，局域网 SYN-ACK 很快）
    ///   - batchSize: 每批并发数
    /// - Returns: 候选列表；扫不到就是空数组（不报错 —— 不在局域网是正常情况）
    static func discover(port: UInt16 = 5555,
                         timeout: TimeInterval = 0.5,
                         batchSize: Int = 64) async -> [Candidate] {

        guard let subnet = localSubnet() else {
            print("[LanDiscovery] 当前不在 WiFi 上（或者拿不到网段）—— 跳过扫描，直接走隧道")
            return []
        }

        let targets = subnet.hosts
        guard !targets.isEmpty else { return [] }

        print("[LanDiscovery] 开始扫 \(subnet.description)，共 \(targets.count) 个地址，端口 \(port)")

        var found: [Candidate] = []
        var index = 0
        while index < targets.count {
            let slice = Array(targets[index..<min(index + batchSize, targets.count)])
            index += batchSize

            let hits = await withTaskGroup(of: String?.self) { group -> [String] in
                for host in slice {
                    group.addTask {
                        isPortOpen(host: host, port: port, timeout: timeout) ? host : nil
                    }
                }
                var results: [String] = []
                for await hit in group {
                    if let hit { results.append(hit) }
                }
                return results
            }
            found.append(contentsOf: hits.map { Candidate(host: $0, port: port) })
        }

        print("[LanDiscovery] 扫完，命中 \(found.count) 台：\(found.map { $0.host })")
        return found.sorted { $0.host < $1.host }
    }

    // MARK: - 拿本机网段

    private struct Subnet {
        let description: String
        let hosts: [String]
    }

    /// 用 getifaddrs 找到本机 **WiFi（en0）** 接口的 IPv4 地址 + 掩码，算出同网段的其他主机。
    ///
    /// ★★ 只认 en0，其它接口一律跳过 —— 尤其是蜂窝（pdp_ip*）：
    ///   切到移动数据后，如果拿蜂窝地址去扫，就是在**移动网络上**扫 253 个地址，
    ///   每个都等到超时，连接会被拖到看起来卡死（用户实测：WiFi 关掉后点连接，
    ///   一直卡在 preparing connection）。而且那条路上根本不可能有手机，
    ///   纯属白费 —— 扫不到就老老实实走隧道才对。
    private static func localSubnet(hostLimit: Int = 1024) -> Subnet? {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        var result: Subnet?
        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddr

        while let current = cursor {
            let flags = Int32(current.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            let family = current.pointee.ifa_addr?.pointee.sa_family
            let name = current.pointee.ifa_name.map { String(cString: $0) } ?? ""

            if isUp, !isLoopback, family == UInt8(AF_INET), name == wifiInterfaceName,
               let addr = current.pointee.ifa_addr,
               let mask = current.pointee.ifa_netmask {

                let ip = ipv4String(from: addr)
                let netmask = ipv4String(from: mask)

                if let ip, let netmask, let subnet = makeSubnet(ip: ip, netmask: netmask, hostLimit: hostLimit) {
                    result = subnet
                    break
                }
            }
            cursor = current.pointee.ifa_next
        }

        return result
    }

    private static func ipv4String(from addr: UnsafeMutablePointer<sockaddr>) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        guard inet_ntop(AF_INET, &sin.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
            return nil
        }
        return String(cString: buffer)
    }

    private static func makeSubnet(ip: String, netmask: String, hostLimit: Int) -> Subnet? {
        func toUInt32(_ s: String) -> UInt32? {
            let parts = s.split(separator: ".").compactMap { UInt32($0) }
            guard parts.count == 4 else { return nil }
            return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
        }

        guard let ipValue = toUInt32(ip), let maskValue = toUInt32(netmask), maskValue != 0 else {
            return nil
        }

        let network = ipValue & maskValue
        let broadcast = network | ~maskValue
        guard broadcast > network + 1 else { return nil }

        // 主机号部分太大就别全扫了（/16 有 6 万多个地址）
        let hostCount = Int(broadcast - network - 1)
        let limit = min(hostCount, hostLimit)

        var hosts: [String] = []
        hosts.reserveCapacity(limit)
        for offset in 1...UInt32(limit) {
            let value = network + offset
            guard value < broadcast else { break }
            let host = "\((value >> 24) & 0xFF).\((value >> 16) & 0xFF).\((value >> 8) & 0xFF).\(value & 0xFF)"
            if host != ip { hosts.append(host) }   // 跳过自己
        }

        return Subnet(description: "\(ip)/\(netmask)", hosts: hosts)
    }

    // MARK: - 端口探测

    /// 非阻塞 connect：SYN 发出去，用 select 等结果。
    /// 局域网里 SYN-ACK 是亚毫秒级的，所以 timeout 给 0.5s 足够；
    /// 不在同一网段的地址会直接超时，快速失败。
    private static func isPortOpen(host: String, port: UInt16, timeout: TimeInterval) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        // 设成非阻塞
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else { return false }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return false }

        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if connectResult == 0 { return true }              // 立刻成功（本机/极快）
        guard errno == EINPROGRESS else { return false }   // 其它错误直接判失败

        // fd_set 在 Swift 里是零初始化的结构体，不用手动 memset
        var writeSet = fd_set()
        var errorSet = fd_set()
        setFd(fd, &writeSet)
        setFd(fd, &errorSet)

        var tv = timeval()
        tv.tv_sec = Int(timeout)
        tv.tv_usec = Int32((timeout - Double(Int(timeout))) * 1_000_000)

        let selectResult = select(fd + 1, nil, &writeSet, &errorSet, &tv)
        guard selectResult > 0 else { return false }

        // 连接成功与否要看 SO_ERROR
        var soError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &length) == 0 else { return false }
        return soError == 0
    }

    private static func setFd(_ fd: Int32, _ set: inout fd_set) {
        let offset = Int(fd / 32)
        let mask = Int32(1 << (fd % 32))
        withUnsafeMutablePointer(to: &set.fds_bits) { ptr in
            ptr.withMemoryRebound(to: Int32.self, capacity: 32) { raw in
                raw[offset] |= mask
            }
        }
    }
}

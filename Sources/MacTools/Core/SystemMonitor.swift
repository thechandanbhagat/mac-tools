import Darwin
import Foundation
import IOKit

struct MonitorCounters: Equatable, Sendable {
    let received: UInt64
    let sent: UInt64
}

struct MonitorCPU: Equatable, Sendable {
    let user: UInt32
    let system: UInt32
    let idle: UInt32
    let nice: UInt32
}

struct SystemMonitorReading: Sendable {
    let uptime: TimeInterval
    let cpu: MonitorCPU?
    let memoryUsed: UInt64?
    let memoryTotal: UInt64
    let diskUsed: Int64?
    let diskTotal: Int64?
    let network: [String: MonitorCounters]?
    let diskIO: [String: MonitorCounters]?
}

struct SystemMonitorSnapshot: Sendable {
    let cpuPercent: Double?
    let memoryUsed: UInt64?
    let memoryTotal: UInt64
    let diskUsed: Int64?
    let diskTotal: Int64?
    let networkReceive: Double?
    let networkSend: Double?
    let diskRead: Double?
    let diskWrite: Double?
}

/// Rates compare matching devices, so a new or removed interface cannot create a spike.
struct SystemMonitorAccumulator: Sendable {
    private var previous: SystemMonitorReading?

    mutating func ingest(_ reading: SystemMonitorReading) -> SystemMonitorSnapshot {
        defer { previous = reading }
        let interval = previous.map { reading.uptime - $0.uptime }
        let validInterval = interval.map { $0 > 0 && $0.isFinite && $0 <= 30 } ?? false
        let network = validInterval ? Self.rate(previous?.network, reading.network, interval!) : nil
        let disk = validInterval ? Self.rate(previous?.diskIO, reading.diskIO, interval!) : nil
        let cpu = validInterval ? Self.cpu(previous?.cpu, reading.cpu) : nil
        return SystemMonitorSnapshot(cpuPercent: cpu, memoryUsed: reading.memoryUsed,
                                     memoryTotal: reading.memoryTotal, diskUsed: reading.diskUsed,
                                     diskTotal: reading.diskTotal, networkReceive: network?.0,
                                     networkSend: network?.1, diskRead: disk?.0, diskWrite: disk?.1)
    }

    private static func rate(_ old: [String: MonitorCounters]?, _ new: [String: MonitorCounters]?,
                             _ elapsed: Double) -> (Double, Double)? {
        guard let old, let new else { return nil }
        if old.isEmpty && new.isEmpty { return (0, 0) }
        var received = 0.0, sent = 0.0, matched = false
        for (name, next) in new {
            guard let prior = old[name], next.received >= prior.received, next.sent >= prior.sent else { continue }
            received += Double(next.received - prior.received)
            sent += Double(next.sent - prior.sent)
            matched = true
        }
        return matched ? (received / elapsed, sent / elapsed) : nil
    }

    private static func cpu(_ old: MonitorCPU?, _ new: MonitorCPU?) -> Double? {
        guard let old, let new else { return nil }
        let active = UInt64(new.user &- old.user) + UInt64(new.system &- old.system) + UInt64(new.nice &- old.nice)
        let total = active + UInt64(new.idle &- old.idle)
        guard total > 0 else { return nil }
        return min(100, max(0, Double(active) / Double(total) * 100))
    }
}

enum SystemMonitorSampler {
    static func read() -> SystemMonitorReading {
        let memoryTotal = ProcessInfo.processInfo.physicalMemory
        let memory = memoryUsage(total: memoryTotal)
        // The data volume carries user storage on modern macOS.
        let volume = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        let total = volume?.volumeTotalCapacity.map(Int64.init)
        let available = volume?.volumeAvailableCapacity.map(Int64.init)
        return SystemMonitorReading(uptime: ProcessInfo.processInfo.systemUptime, cpu: cpuUsage(),
                                    memoryUsed: memory, memoryTotal: memoryTotal,
                                    diskUsed: total.flatMap { total in available.map { max(0, total - $0) } },
                                    diskTotal: total, network: networkCounters(), diskIO: diskCounters())
    }

    private static func cpuUsage() -> MonitorCPU? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        return MonitorCPU(user: info.cpu_ticks.0, system: info.cpu_ticks.1, idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
    }

    private static func memoryUsage(total: UInt64) -> UInt64? {
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        guard host_page_size(host, &pageSize) == KERN_SUCCESS else { return nil }
        let pages = UInt64(info.active_count) + UInt64(info.wire_count) + UInt64(info.compressor_page_count)
        return min(total, pages * UInt64(pageSize))
    }

    private static func networkCounters() -> [String: MonitorCounters]? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }
        var result: [String: MonitorCounters] = [:]
        var unavailable = false
        var cursor = head
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let value = entry.pointee
            guard let address = value.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  value.ifa_flags & UInt32(IFF_UP) != 0,
                  value.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: value.ifa_name)
            // Ethernet/Wi-Fi and cellular links; exclude bridges and VPN tunnels to avoid double counting.
            guard name.hasPrefix("en") || name.hasPrefix("pdp_ip") else { continue }
            let index = if_nametoindex(value.ifa_name)
            guard index > 0, index <= Int32.max else { unavailable = true; continue }
            // getifaddrs exposes 32-bit counters. The public interface MIB provides
            // 64-bit totals that do not wrap after every 4 GB transfer.
            var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, Int32(index), IFDATA_GENERAL]
            var statistics = ifmibdata()
            var size = MemoryLayout<ifmibdata>.size
            guard sysctl(&mib, UInt32(mib.count), &statistics, &size, nil, 0) == 0,
                  size == MemoryLayout<ifmibdata>.size else { unavailable = true; continue }
            result["\(name):\(index)"] = MonitorCounters(received: statistics.ifmd_data.ifi_ibytes,
                                                       sent: statistics.ifmd_data.ifi_obytes)
        }
        return unavailable ? nil : result
    }

    private static func diskCounters() -> [String: MonitorCounters]? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var result: [String: MonitorCounters] = [:]
        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != 0 else { break }
            defer { IOObjectRelease(entry) }
            guard let property = IORegistryEntryCreateCFProperty(entry, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
                  let values = property as? [String: Any],
                  let read = values["Bytes (Read)"] as? NSNumber,
                  let written = values["Bytes (Write)"] as? NSNumber else { continue }
            var identifier: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(entry, &identifier) == KERN_SUCCESS else { continue }
            result[String(identifier)] = MonitorCounters(received: read.uint64Value, sent: written.uint64Value)
        }
        return result.isEmpty ? nil : result
    }
}

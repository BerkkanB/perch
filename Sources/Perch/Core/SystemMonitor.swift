import Darwin
import Foundation
import Observation

/// How full the startup disk is.
struct StorageReading: Equatable {
    var total: Int64
    /// What Finder calls "available": free space plus what macOS can purge on demand.
    var available: Int64

    enum Level { case ok, low, critical }

    var used: Int64 { max(0, total - available) }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    /// macOS needs about 20 GB for an update and room for swap, so the levels are in gigabytes
    /// rather than a share of the disk.
    var level: Level {
        if available < 10 * ByteFormat.gigabyte { return .critical }
        if available < 30 * ByteFormat.gigabyte { return .low }
        return .ok
    }
}

/// How much memory is in use, counted the way Activity Monitor does.
struct MemoryReading: Equatable {
    var total: Int64
    /// App memory, wired and compressed: Activity Monitor's "Memory Used".
    var used: Int64
    var swapUsed: Int64
    var pressure: Pressure

    /// macOS's memory pressure, the green, yellow and red graph in Activity Monitor.
    enum Pressure {
        case normal, warning, critical

        var label: String {
            switch self {
            case .normal: "Normal"
            case .warning: "High"
            case .critical: "Critical"
            }
        }
    }

    var usedFraction: Double { total > 0 ? min(1, Double(used) / Double(total)) : 0 }
}

/// Startup disk space and memory, read every few seconds and whenever a panel opens.
@MainActor
@Observable
final class SystemMonitor {
    private(set) var storage: StorageReading?
    private(set) var memory: MemoryReading?

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var ticks = 0

    func start() {
        // Memory reads take microseconds; disk space changes slowly, so it's read every 30 s.
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func update() {
        storage = Self.readStorage()
        memory = Self.readMemory()
    }

    private func tick() {
        if ticks % 6 == 0 { storage = Self.readStorage() }
        memory = Self.readMemory()
        ticks += 1
    }

    // MARK: Reading

    private static func readStorage() -> StorageReading? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? home.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let total = values.volumeTotalCapacity, total > 0,
              let available = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return StorageReading(total: Int64(total), available: available)
    }

    private static let host = mach_host_self()

    private static func readMemory() -> MemoryReading? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        var pageSize: vm_size_t = 0
        guard result == KERN_SUCCESS, host_page_size(host, &pageSize) == KERN_SUCCESS else { return nil }

        let page = Int64(pageSize)
        let app = Int64(stats.internal_page_count) - Int64(stats.purgeable_count)
        let used = (max(0, app) + Int64(stats.wire_count) + Int64(stats.compressor_page_count)) * page

        return MemoryReading(
            total: Int64(ProcessInfo.processInfo.physicalMemory),
            used: used,
            swapUsed: readSwapUsed(),
            pressure: readPressure()
        )
    }

    private static func readSwapUsed() -> Int64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return Int64(usage.xsu_used)
    }

    private static func readPressure() -> MemoryReading.Pressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
        // The kernel's levels: 1 normal, 2 warning, 4 critical.
        switch level {
        case 4: return .critical
        case 2: return .warning
        default: return .normal
        }
    }
}

#if DEBUG
extension SystemMonitor {
    /// For snapshots of the warning colors.
    func setPreview(storage: StorageReading?, memory: MemoryReading?) {
        pollTask?.cancel()
        self.storage = storage
        self.memory = memory
    }
}
#endif

/// Sizes the way macOS shows them: disk space in decimal units like Finder ("82 GB"), memory in
/// binary units like Activity Monitor ("16 GB" for 16 GiB).
enum ByteFormat {
    static let gigabyte: Int64 = 1_000_000_000
    static let gibibyte: Int64 = 1 << 30

    /// "8.4 GB", "82 GB", "1.2 TB", "2 TB"
    static func storage(_ bytes: Int64) -> String {
        let gigabytes = Double(bytes) / Double(gigabyte)
        if gigabytes >= 1000 { return "\(oneDecimal(gigabytes / 1000)) TB" }
        if gigabytes >= 10 { return "\(Int(gigabytes.rounded())) GB" }
        if gigabytes >= 1 { return "\(oneDecimal(gigabytes)) GB" }
        return "\(Int((Double(bytes) / 1_000_000).rounded())) MB"
    }

    /// "11.2 GB", "16 GB", "640 MB"
    static func memory(_ bytes: Int64) -> String {
        let gibibytes = Double(bytes) / Double(gibibyte)
        if gibibytes >= 1 { return "\(oneDecimal(gibibytes)) GB" }
        return "\(Int((Double(bytes) / Double(1 << 20)).rounded())) MB"
    }

    /// "17.6 of 24 GB", with the unit once when both are in gigabytes.
    static func memory(_ used: Int64, of total: Int64) -> String {
        guard used >= gibibyte, total >= gibibyte else { return "\(memory(used)) of \(memory(total))" }
        return "\(oneDecimal(Double(used) / Double(gibibyte))) of \(memory(total))"
    }

    /// One decimal, dropped when it's zero: "1.2", "16".
    private static func oneDecimal(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? "\(Int(rounded))" : String(format: "%.1f", rounded)
    }
}

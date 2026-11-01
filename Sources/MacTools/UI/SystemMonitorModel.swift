import SwiftUI

@MainActor
final class SystemMonitorModel: ObservableObject {
    typealias Sample = @Sendable () async -> SystemMonitorReading
    @Published private(set) var snapshot: SystemMonitorSnapshot?
    @Published private(set) var isRunning = false
    @Published private(set) var sampledAt: Date?
    let isDemo: Bool
    private let sample: Sample
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(isDemo: Bool = AppEnvironment.isDemo, sample: Sample? = nil) {
        self.isDemo = isDemo
        self.sample = sample ?? {
            if isDemo { return Self.demoReading() }
            return await Task.detached(priority: .utility) { SystemMonitorSampler.read() }.value
        }
    }

    var isBusy: Bool { isRunning && snapshot == nil }
    var summaryTitle: String {
        guard let percent = snapshot?.cpuPercent else { return isDemo ? "Demo CPU —" : "CPU —" }
        return "\(isDemo ? "Demo " : "")CPU \(Int(percent.rounded()))%"
    }

    func start() {
        guard task == nil else { return }
        isRunning = true
        let token = UUID()
        generation = token
        let sample = sample
        task = Task { [weak self] in
            var accumulator = SystemMonitorAccumulator()
            var isFirst = true
            while !Task.isCancelled {
                let reading = await sample()
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.snapshot = accumulator.ingest(reading)
                self.sampledAt = Date()
                let delay: Duration = isFirst ? .milliseconds(300) : .seconds(2)
                isFirst = false
                do { try await Task.sleep(for: delay) } catch { return }
            }
        }
    }

    func stop() {
        generation = UUID()
        task?.cancel()
        task = nil
        isRunning = false
    }

    func refresh() { stop(); start() }
    func shutdown() { stop() }

    private nonisolated static func demoReading() -> SystemMonitorReading {
        let time = ProcessInfo.processInfo.systemUptime
        let ticks = UInt32(time.truncatingRemainder(dividingBy: 1_000_000) * 100)
        let counter = UInt64(time * 1_000_000)
        return SystemMonitorReading(uptime: time,
                                    cpu: MonitorCPU(user: ticks / 8, system: ticks / 16, idle: ticks * 3 / 4, nice: 0),
                                    memoryUsed: 8_700_000_000, memoryTotal: 17_179_869_184,
                                    diskUsed: 283_000_000_000, diskTotal: 500_000_000_000,
                                    network: ["en0": MonitorCounters(received: counter, sent: counter / 10)],
                                    diskIO: ["disk0": MonitorCounters(received: counter * 4, sent: counter / 2)])
    }
}

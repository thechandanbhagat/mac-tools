import XCTest
@testable import MacTools

final class SystemMonitorTests: XCTestCase {
    func testFirstSampleProvidesGaugesButNoInventedRates() {
        var accumulator = SystemMonitorAccumulator()
        let value = accumulator.ingest(reading(time: 1, cpu: cpu(0, 0), network: ["en0": counters(100, 50)]))
        XCTAssertNil(value.cpuPercent)
        XCTAssertNil(value.networkReceive)
        XCTAssertNil(value.diskRead)
        XCTAssertEqual(value.memoryUsed, 4_000)
        XCTAssertEqual(value.diskUsed, 25_000)
    }

    func testCPUAndByteRatesUseElapsedTime() {
        var accumulator = SystemMonitorAccumulator()
        _ = accumulator.ingest(reading(time: 10, cpu: cpu(10, 90), network: ["en0": counters(100, 50)], disk: ["disk0": counters(10, 20)]))
        let value = accumulator.ingest(reading(time: 12, cpu: cpu(50, 150), network: ["en0": counters(500, 150)], disk: ["disk0": counters(2010, 1020)]))
        XCTAssertEqual(value.cpuPercent, 40)
        XCTAssertEqual(value.networkReceive, 200)
        XCTAssertEqual(value.networkSend, 50)
        XCTAssertEqual(value.diskRead, 1_000)
        XCTAssertEqual(value.diskWrite, 500)
    }

    func testHotPluggedAndRemovedInterfacesDoNotCreateSpikes() {
        var accumulator = SystemMonitorAccumulator()
        _ = accumulator.ingest(reading(time: 1, network: ["en0": counters(1_000, 500), "en1": counters(9_000_000, 2_000)]))
        let value = accumulator.ingest(reading(time: 3, network: ["en0": counters(1_200, 600), "en2": counters(50_000_000, 30_000_000)]))
        XCTAssertEqual(value.networkReceive, 100)
        XCTAssertEqual(value.networkSend, 50)
    }

    func testResetCountersDoNotUnderflowAndResumeOnNextReading() {
        var accumulator = SystemMonitorAccumulator()
        _ = accumulator.ingest(reading(time: 1, network: ["en0": counters(UInt64.max - 1, 3_000)]))
        XCTAssertNil(accumulator.ingest(reading(time: 3, network: ["en0": counters(100, 50)])).networkReceive)
        XCTAssertEqual(accumulator.ingest(reading(time: 5, network: ["en0": counters(300, 150)])).networkReceive, 100)
    }

    func testSleepOrNonIncreasingClockStartsNewBaseline() {
        var accumulator = SystemMonitorAccumulator()
        _ = accumulator.ingest(reading(time: 10, cpu: cpu(10, 20), network: ["en0": counters(100, 100)]))
        XCTAssertNil(accumulator.ingest(reading(time: 10, cpu: cpu(20, 40), network: ["en0": counters(200, 200)])).cpuPercent)
        XCTAssertNil(accumulator.ingest(reading(time: 100, network: ["en0": counters(1_000, 1_000)])).networkReceive)
        XCTAssertEqual(accumulator.ingest(reading(time: 102, network: ["en0": counters(1_200, 1_200)])).networkReceive, 100)
    }

    func testUnavailableCountersRemainUnavailableAndDisconnectedNetworkIsZero() {
        var accumulator = SystemMonitorAccumulator()
        _ = accumulator.ingest(reading(time: 1, network: [:]))
        let value = accumulator.ingest(reading(time: 3, network: [:]))
        XCTAssertEqual(value.networkReceive, 0)
        XCTAssertNil(value.diskRead)
        XCTAssertNil(value.cpuPercent)
    }

    func testCPUTickRolloverProducesBoundedUsage() {
        var accumulator = SystemMonitorAccumulator()
        _ = accumulator.ingest(reading(time: 1, cpu: cpu(UInt32.max - 9, UInt32.max - 9)))
        let value = accumulator.ingest(reading(time: 3, cpu: cpu(10, 10)))
        XCTAssertEqual(value.cpuPercent, 50)
    }

    func testLiveSamplerReturnsBoundedLocalGauges() {
        let value = SystemMonitorSampler.read()
        XCTAssertGreaterThan(value.uptime, 0)
        XCTAssertGreaterThan(value.memoryTotal, 0)
        if let used = value.memoryUsed { XCTAssertLessThanOrEqual(used, value.memoryTotal) }
        if let used = value.diskUsed, let total = value.diskTotal {
            XCTAssertGreaterThanOrEqual(used, 0)
            XCTAssertLessThanOrEqual(used, total)
        }
    }

    private func cpu(_ active: UInt32, _ idle: UInt32) -> MonitorCPU { MonitorCPU(user: active, system: 0, idle: idle, nice: 0) }
    private func counters(_ received: UInt64, _ sent: UInt64) -> MonitorCounters { MonitorCounters(received: received, sent: sent) }
    private func reading(time: Double, cpu: MonitorCPU? = nil, network: [String: MonitorCounters]? = nil, disk: [String: MonitorCounters]? = nil) -> SystemMonitorReading {
        SystemMonitorReading(uptime: time, cpu: cpu, memoryUsed: 4_000, memoryTotal: 8_000, diskUsed: 25_000, diskTotal: 100_000, network: network, diskIO: disk)
    }
}

@MainActor
final class SystemMonitorModelTests: XCTestCase {
    func testStartIsIdempotentAndShutdownRejectsAnInFlightReading() async throws {
        let source = MonitorGate()
        let model = SystemMonitorModel(isDemo: false, sample: { await source.read() })
        model.start()
        model.start()
        for _ in 0..<100 {
            if await source.count == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let count = await source.count
        XCTAssertEqual(count, 1)
        model.shutdown()
        await source.finish()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(model.isRunning)
        XCTAssertFalse(model.isBusy)
        XCTAssertNil(model.snapshot)
    }
}

private actor MonitorGate {
    private(set) var count = 0
    private var continuation: CheckedContinuation<SystemMonitorReading, Never>?
    func read() async -> SystemMonitorReading {
        count += 1
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish() {
        continuation?.resume(returning: SystemMonitorReading(uptime: 1, cpu: nil, memoryUsed: 1, memoryTotal: 2, diskUsed: nil, diskTotal: nil, network: nil, diskIO: nil))
        continuation = nil
    }
}

import Darwin
import Foundation

public enum NetworkTransportProtocol: String, CaseIterable, Identifiable, Sendable {
    case tcp = "TCP"
    case udp = "UDP"

    public var id: String { rawValue }
}

public struct ListeningPortItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let pid: Int32
    public let processName: String
    public let executablePath: String?
    public let userID: uid_t
    public let transport: NetworkTransportProtocol
    public let address: String
    public let port: Int
    public let ipVersion: String

    public init(
        pid: Int32,
        processName: String,
        executablePath: String?,
        userID: uid_t,
        transport: NetworkTransportProtocol,
        address: String,
        port: Int,
        ipVersion: String = "IPv4"
    ) {
        self.id = "\(pid)-\(transport.rawValue)-\(ipVersion)-\(address):\(port)"
        self.pid = pid
        self.processName = processName
        self.executablePath = executablePath
        self.userID = userID
        self.transport = transport
        self.address = address
        self.port = port
        self.ipVersion = ipVersion
    }

    public var displayEndpoint: String {
        "\(address):\(port)"
    }

    public var isCurrentUser: Bool {
        userID == getuid()
    }
}

public enum PortInspectorError: LocalizedError, Equatable {
    case refused(String)
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .refused(let message), .commandFailed(let message):
            message
        }
    }
}

struct PortInspector: Sendable {
    typealias CommandRunner = @Sendable () throws -> String
    typealias SignalSender = @Sendable (pid_t, Int32) -> Int32
    typealias PathResolver = @Sendable (pid_t) -> String?

    private let runLsof: CommandRunner
    private let sendSignal: SignalSender
    private let resolvePath: PathResolver

    init(
        runLsof: @escaping CommandRunner = { try Self.executeLsof() },
        sendSignal: @escaping SignalSender = { Darwin.kill($0, $1) },
        resolvePath: @escaping PathResolver = { Self.executablePath(for: $0) }
    ) {
        self.runLsof = runLsof
        self.sendSignal = sendSignal
        self.resolvePath = resolvePath
    }

    public func listListeningPorts() throws -> [ListeningPortItem] {
        try Task.checkCancellation()
        let rawOutput = try runLsof()
        try Task.checkCancellation()
        return Self.parseLsofFieldOutput(rawOutput, resolvePath: resolvePath)
    }

    public func terminate(_ item: ListeningPortItem, force: Bool) throws {
        try Task.checkCancellation()
        let currentPID = ProcessInfo.processInfo.processIdentifier
        guard item.pid > 1, item.pid != currentPID else {
            throw PortInspectorError.refused("System processes and Mac Tools itself cannot be quit from Active Ports.")
        }
        guard item.userID == getuid() else {
            throw PortInspectorError.refused("Only processes owned by your user account can be quit without administrator privileges.")
        }
        if let expectedPath = item.executablePath,
           let currentPath = resolvePath(item.pid),
           currentPath != expectedPath {
            throw PortInspectorError.refused("The process on port \(item.port) changed since refreshing. Refresh the list before trying again.")
        }
        let sig = force ? SIGKILL : SIGTERM
        guard sendSignal(item.pid, sig) == 0 else {
            let code = errno
            if code == ESRCH {
                throw PortInspectorError.refused("Process \(item.processName) (PID \(item.pid)) is no longer running.")
            }
            if code == EPERM {
                throw PortInspectorError.refused("macOS refused permission to stop \(item.processName) (PID \(item.pid)).")
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
    }

    public static func parseLsofFieldOutput(
        _ output: String,
        resolvePath: (pid_t) -> String? = { executablePath(for: $0) }
    ) -> [ListeningPortItem] {
        var items: [ListeningPortItem] = []
        var seen = Set<String>()

        var currentPID: Int32?
        var currentCommand = ""
        var currentUID: uid_t = getuid()
        var currentPath: String?
        var currentType = "IPv4"
        var currentProto: NetworkTransportProtocol?

        for rawLine in output.split(whereSeparator: \.isNewline) {
            guard let prefix = rawLine.first else { continue }
            let value = String(rawLine.dropFirst())

            switch prefix {
            case "p":
                if let pid = Int32(value) {
                    currentPID = pid
                    currentCommand = ""
                    currentUID = getuid()
                    currentPath = resolvePath(pid)
                    currentType = "IPv4"
                    currentProto = nil
                }
            case "c":
                currentCommand = value
            case "u":
                if let uid = UInt32(value) {
                    currentUID = uid
                }
            case "t":
                if value == "IPv6" || value == "IPv4" {
                    currentType = value
                }
            case "P":
                if value.uppercased() == "TCP" {
                    currentProto = .tcp
                } else if value.uppercased() == "UDP" {
                    currentProto = .udp
                } else {
                    currentProto = nil
                }
            case "n":
                guard let pid = currentPID, let proto = currentProto else { continue }
                // Exclude connected sockets with "->"
                guard !value.contains("->") else { continue }
                guard let colonIndex = value.lastIndex(of: ":") else { continue }
                let hostPart = String(value[..<colonIndex])
                let portPart = String(value[value.index(after: colonIndex)...])
                guard let port = Int(portPart), port > 0 && port <= 65535 else { continue }
                let displayHost = hostPart == "*" ? "0.0.0.0" : hostPart
                let name = currentCommand.isEmpty
                    ? (currentPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "PID \(pid)")
                    : currentCommand
                let entry = ListeningPortItem(
                    pid: pid,
                    processName: name,
                    executablePath: currentPath,
                    userID: currentUID,
                    transport: proto,
                    address: displayHost,
                    port: port,
                    ipVersion: currentType
                )
                if seen.insert(entry.id).inserted {
                    items.append(entry)
                }
            default:
                break
            }
        }

        return items.sorted { lhs, rhs in
            if lhs.port != rhs.port { return lhs.port < rhs.port }
            if lhs.processName != rhs.processName {
                return lhs.processName.localizedStandardCompare(rhs.processName) == .orderedAscending
            }
            return lhs.pid < rhs.pid
        }
    }

    public static func executablePath(for pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(validatingCString: buffer)
    }

    static func executeLsof() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP", "-sTCP:LISTEN", "-iUDP", "-F", "pcnPtTu"]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else {
            return ""
        }
        return output
    }
}

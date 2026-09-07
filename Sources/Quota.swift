import Foundation
import Combine
import Darwin

struct QuotaWindow: Decodable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Double?

    var remaining: Int { Int(max(0, min(100, 100 - usedPercent)).rounded(.down)) }
    var detail: String {
        let duration = windowDurationMins.map { $0 % 1440 == 0 ? "\($0 / 1440) j" : "\($0) min" } ?? "durée inconnue"
        let reset = resetsAt.map { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened) } ?? "inconnue"
        return "\(duration) : \(remaining)% restants · réinitialisation : \(reset)"
    }
}

struct QuotaSnapshot: Decodable {
    let primary: QuotaWindow?
    let secondary: QuotaWindow?
    var windows: [QuotaWindow] { [primary, secondary].compactMap { $0 } }
    var remaining: Int? { windows.map(\.remaining).min() }

    static func parse(_ data: Data) throws -> QuotaSnapshot {
        struct Response: Decodable {
            struct Result: Decodable {
                let rateLimits: QuotaSnapshot?
                let rateLimitsByLimitId: [String: QuotaSnapshot]?
            }
            let result: Result
        }
        let result = try JSONDecoder().decode(Response.self, from: data).result
        let snapshot = result.rateLimitsByLimitId.map { $0["codex"] } ?? result.rateLimits
        guard let snapshot, snapshot.remaining != nil else { throw QuotaError.unavailable }
        return snapshot
    }
}

private enum QuotaError: LocalizedError {
    case unavailable, missingCLI, timeout
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Quota Codex indisponible"
        case .missingCLI: return "CLI Codex introuvable"
        case .timeout: return "Codex ne répond pas"
        }
    }
}

struct CodexQuotaReader {
    var executable: URL? = nil
    var timeout: TimeInterval = 15

    func load() throws -> QuotaSnapshot {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/codex", "/Applications/ChatGPT.app/Contents/Resources/codex", "/Applications/Codex.app/Contents/Resources/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/codex" }
        guard let executable = executable ?? candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map({ URL(fileURLWithPath: $0) }) else { throw QuotaError.missingCLI }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            let end = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < end { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
        }
        func send(_ message: String) throws {
            try input.fileHandleForWriting.write(contentsOf: Data((message + "\n").utf8))
        }
        try send(#"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"codex_models","version":"1.0"}}}"#)
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = Data()
        let fd = output.fileHandleForReading.fileDescriptor
        while Date() < deadline {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 100) > 0 else { continue }
            var bytes = [UInt8](repeating: 0, count: 8192)
            let count = read(fd, &bytes, bytes.count)
            guard count > 0 else { throw QuotaError.unavailable }
            buffer.append(contentsOf: bytes.prefix(count))
            guard buffer.count <= 1_048_576 else { throw QuotaError.unavailable }
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let id = object["id"] as? Int else { continue }
                if id == 1 {
                    guard object["error"] == nil else { throw QuotaError.unavailable }
                    try send(#"{"method":"initialized"}"#)
                    try send(#"{"id":2,"method":"account/rateLimits/read"}"#)
                } else if id == 2 {
                    return try QuotaSnapshot.parse(line)
                }
            }
        }
        throw QuotaError.timeout
    }
}

@MainActor
final class QuotaModel: ObservableObject {
    @Published private(set) var snapshot: QuotaSnapshot?
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastSuccess: Date?
    private(set) var isRefreshing = false
    private let queue = DispatchQueue(label: "local.sanz.codexmodels.quota")
    private let load: () throws -> QuotaSnapshot
    private var timer: Timer?

    init(interval: TimeInterval = 30, load: @escaping () throws -> QuotaSnapshot = { try CodexQuotaReader().load() }) {
        self.load = load
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    var menuText: String { snapshot?.remaining.map { "\($0)%" } ?? "—" }
    var tooltip: String {
        guard let snapshot else { return errorMessage ?? "Chargement du quota Codex…" }
        return (["Quota Codex"] + snapshot.windows.map(\.detail) + ["Actualisation automatique toutes les 30 s"]).joined(separator: "\n")
    }
    func stopMonitoring() { timer?.invalidate(); timer = nil }
    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let load = load
        queue.async {
            let result = Result { try load() }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch result {
                case .success(let snapshot):
                    self.snapshot = snapshot
                    self.lastSuccess = Date()
                    self.errorMessage = nil
                case .failure(let error):
                    self.snapshot = nil
                    self.errorMessage = (error as? QuotaError)?.localizedDescription
                        ?? "Quota indisponible · vérifier le réseau et le compte connecté dans Codex"
                }
                self.isRefreshing = false
            }
        }
    }
}

import Foundation
import SQLite3

enum RunStatus: String, Sendable {
    case running, completed, interrupted, failed, unknown

    var label: String {
        switch self {
        case .running: return "En cours"
        case .completed: return "Terminé"
        case .interrupted: return "Interrompu"
        case .failed: return "Échec"
        case .unknown: return "Inconnu"
        }
    }

    init(stored: String?) {
        switch stored {
        case "inProgress": self = .running
        case "completed": self = .completed
        case "interrupted": self = .interrupted
        case "failed": self = .failed
        default: self = .unknown
        }
    }
}

struct Conversation: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let model: String
    let effort: String
    let status: RunStatus
    let createdAt: TimeInterval
    var children: [Conversation]
    var parentTitle: String? = nil
    var turnStartedAt: Date? = nil

    var codexURL: URL? {
        guard UUID(uuidString: id) != nil else { return nil }
        return URL(string: "codex://threads/\(id)")
    }

    var descendants: [Conversation] {
        children.flatMap { [$0] + $0.descendants }
    }

    var activeCount: Int {
        (status == .running ? 1 : 0) + children.reduce(0) { $0 + $1.activeCount }
    }

    func filtered(showCompleted: Bool) -> [Conversation] {
        var result = self
        result.children = children.flatMap { $0.filtered(showCompleted: showCompleted) }
        if !showCompleted && [.completed, .interrupted, .failed].contains(status) { return result.children }
        return [result]
    }
}

private struct DatabaseError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// The connection is short-lived and cannot mutate Codex's databases.
final class ReadDatabase {
    private var handle: OpaquePointer?

    init(_ url: URL) throws {
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let detail = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "inaccessible"
            sqlite3_close(handle)
            handle = nil
            throw DatabaseError(message: "Lecture de \(url.lastPathComponent) impossible : \(detail)")
        }
        sqlite3_busy_timeout(handle, 300)
    }

    deinit { sqlite3_close(handle) }

    func rows(_ sql: String) throws -> [[String: String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError(message: "Schéma Codex incompatible : \(String(cString: sqlite3_errmsg(handle)))")
        }
        defer { sqlite3_finalize(statement) }
        var result: [[String: String]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else {
                throw DatabaseError(message: "Lecture Codex interrompue : \(String(cString: sqlite3_errmsg(handle)))")
            }
            var row: [String: String] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                if let text = sqlite3_column_text(statement, column) {
                    row[String(cString: sqlite3_column_name(statement, column))] = String(cString: text)
                }
            }
            result.append(row)
        }
    }
}

final class CodexReader: @unchecked Sendable {
    private let directory: URL

    init(directory: URL) { self.directory = directory }

    func load() throws -> [Conversation] {
        let database = try ReadDatabase(directory.appendingPathComponent("state_5.sqlite"))
        // One read transaction keeps thread names and parent links consistent.
        _ = try database.rows("BEGIN")
        var threads = try database.rows("""
            SELECT id, name, title, model, reasoning_effort, agent_path, agent_nickname, archived, source,
                   COALESCE(created_at_ms / 1000.0, created_at) AS created_at, rollout_path
            FROM threads ORDER BY recency_at DESC, updated_at DESC, id
            """)
        let edges = try database.rows("SELECT parent_thread_id, child_thread_id FROM thread_spawn_edges")
        _ = try database.rows("COMMIT")

        // Legacy renames live in the append-only index, not in threads.name.
        let titles = legacyTitles()
        for index in threads.indices {
            if (threads[index]["name"] ?? "").isEmpty, let id = threads[index]["id"], let title = titles[id] {
                threads[index]["name"] = title
            }
        }

        var statuses: [String: RunStatus] = [:]
        var turnStarts: [String: Date] = [:]
        let historyURL = directory.appendingPathComponent("thread_history_1.sqlite")
        if FileManager.default.fileExists(atPath: historyURL.path) {
            let history = try ReadDatabase(historyURL)
            for row in try history.rows("""
                SELECT t.thread_id, t.status FROM thread_turns AS t
                WHERE t.rollout_ordinal = (
                    SELECT MAX(last.rollout_ordinal) FROM thread_turns AS last
                    WHERE last.thread_id = t.thread_id
                )
                """) {
                if let id = row["thread_id"] { statuses[id] = RunStatus(stored: row["status"]) }
            }
        }
        let visible = Self.tree(threads: threads, edges: edges, statuses: statuses)
        let visibleIDs = Set(visible.flatMap { [$0] + $0.descendants }.map(\.id))
        // The history projection can lag behind resumed turns, including paginated threads.
        for row in threads {
            if let id = row["id"], visibleIDs.contains(id), let path = row["rollout_path"] {
                let event = rolloutStatus(at: URL(fileURLWithPath: path))
                if event.status != .unknown { statuses[id] = event.status }
                turnStarts[id] = event.startedAt
            }
        }
        return Self.tree(threads: threads, edges: edges, statuses: statuses, turnStarts: turnStarts)
    }

    private func legacyTitles() -> [String: String] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("session_index.jsonl")) else { return [:] }
        var titles: [String: String] = [:]
        for line in data.split(separator: 10) {
            if let item = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
               let id = item["id"] as? String, let title = item["thread_name"] as? String, !title.isEmpty {
                titles[id] = title
            }
        }
        return titles
    }

    private func rolloutStatus(at url: URL) -> (status: RunStatus, startedAt: Date?) {
        guard let file = try? FileHandle(forReadingFrom: url) else { return (.unknown, nil) }
        defer { try? file.close() }
        do {
            var offset = try file.seekToEnd()
            var partial = Data()
            // Read backwards to the latest lifecycle event, rather than reloading a large transcript.
            while offset > 0 {
                let start = offset > 65_536 ? offset - 65_536 : 0
                try file.seek(toOffset: start)
                var block = try file.read(upToCount: Int(offset - start)) ?? Data()
                block.append(partial)
                let lines = block.split(separator: 10, omittingEmptySubsequences: false)
                for line in lines.dropFirst(start > 0 ? 1 : 0).reversed() {
                    guard line.range(of: Data("\"event_msg\"".utf8)) != nil,
                          let record = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                          record["type"] as? String == "event_msg",
                          let payload = record["payload"] as? [String: Any] else { continue }
                    switch payload["type"] as? String {
                    case "task_complete": return (.completed, nil)
                    case "task_started":
                        let formatter = ISO8601DateFormatter()
                        let timestamp = record["timestamp"] as? String ?? ""
                        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                        let fractional = formatter.date(from: timestamp)
                        formatter.formatOptions = [.withInternetDateTime]
                        return (.running, fractional ?? formatter.date(from: timestamp))
                    case "turn_aborted": return (.interrupted, nil)
                    case "task_failed": return (.failed, nil)
                    default: continue
                    }
                }
                partial = start > 0 ? Data(lines.first ?? Data.SubSequence()) : Data()
                offset = start
            }
        } catch { return (.unknown, nil) }
        return (.unknown, nil)
    }

    static func tree(threads: [[String: String]], edges: [[String: String]],
                     statuses: [String: RunStatus], turnStarts: [String: Date] = [:]) -> [Conversation] {
        let records = Dictionary(threads.compactMap { row in
            row["id"].map { ($0, row) }
        }, uniquingKeysWith: { first, _ in first })
        var parents: [String: String] = [:]
        for edge in edges {
            if let parent = edge["parent_thread_id"], let child = edge["child_thread_id"],
               parent != child, records[parent] != nil, records[child] != nil {
                parents[child] = parent
            }
        }
        var childIDs: [String: [String]] = [:]
        for row in threads {
            if let id = row["id"], let parent = parents[id] {
                childIDs[parent, default: []].append(id)
            }
        }

        func make(_ id: String, ancestors: Set<String>, parentTitle: String? = nil) -> Conversation? {
            guard !ancestors.contains(id), let row = records[id], row["archived"] != "1" else { return nil }
            func value(_ key: String) -> String? {
                guard let text = row[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { return nil }
                return text
            }
            let title = value("name")
                ?? value("agent_path").map { ($0 as NSString).lastPathComponent }
                ?? value("title") ?? value("agent_nickname") ?? "Sans titre"
            return Conversation(
                id: id, title: title, model: value("model") ?? "Non fourni",
                effort: value("reasoning_effort") ?? "Non fourni",
                status: statuses[id] ?? .unknown,
                createdAt: Double(row["created_at"] ?? "") ?? 0,
                children: (childIDs[id] ?? []).compactMap { make($0, ancestors: ancestors.union([id]), parentTitle: title) },
                parentTitle: parentTitle, turnStartedAt: turnStarts[id]
            )
        }
        return threads.compactMap { row in
            guard let id = row["id"], row["archived"] != "1", parents[id] == nil,
                  ["vscode", "cli"].contains(row["source"] ?? ""),
                  [row["name"], row["title"]].contains(where: {
                      !($0 ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  }) else { return nil }
            return make(id, ancestors: [])
        }
    }
}

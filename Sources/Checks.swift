import Foundation
import SQLite3

@MainActor
func runChecks() {
    do {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        func fixture(_ file: String, _ sql: String) throws {
            var db: OpaquePointer?
            guard sqlite3_open(directory.appendingPathComponent(file).path, &db) == SQLITE_OK else {
                throw NSError(domain: "Fixture", code: 1)
            }
            defer { sqlite3_close(db) }
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw NSError(domain: "Fixture", code: 2)
            }
        }

        try fixture("state_5.sqlite", """
            CREATE TABLE threads (id TEXT PRIMARY KEY, name TEXT, title TEXT, model TEXT,
                reasoning_effort TEXT, agent_path TEXT, agent_nickname TEXT, archived INTEGER,
                recency_at INTEGER, updated_at INTEGER, source TEXT);
            CREATE TABLE thread_spawn_edges (parent_thread_id TEXT, child_thread_id TEXT, status TEXT);
            INSERT INTO threads VALUES ('root','Conversation renommée','Ancien titre','gpt-6-astra',
                'high',NULL,NULL,0,3,3,'vscode');
            INSERT INTO threads VALUES ('child',NULL,'','gpt-5.6-luna','max',
                '/root/verification','Nom interne',0,2,2,'subagent');
            INSERT INTO threads VALUES ('archived','Archive','',NULL,NULL,NULL,NULL,1,1,1,'vscode');
            INSERT INTO threads VALUES ('headless','Test CLI','',NULL,NULL,NULL,NULL,0,4,4,'exec');
            INSERT INTO threads VALUES ('empty',NULL,'',NULL,NULL,NULL,NULL,0,5,5,'cli');
            INSERT INTO threads VALUES ('archived-child',NULL,'','gpt-5.6-luna','max',
                '/root/old',NULL,1,1,1,'subagent');
            INSERT INTO thread_spawn_edges VALUES ('root','child','open');
            INSERT INTO thread_spawn_edges VALUES ('root','archived-child','open');
            ALTER TABLE threads ADD COLUMN created_at REAL NOT NULL DEFAULT 0;
            ALTER TABLE threads ADD COLUMN created_at_ms INTEGER;
            ALTER TABLE threads ADD COLUMN rollout_path TEXT;
            ALTER TABLE threads ADD COLUMN history_mode TEXT NOT NULL DEFAULT 'paginated';
            """)
        try fixture("thread_history_1.sqlite", """
            CREATE TABLE thread_turns (thread_id TEXT, rollout_ordinal INTEGER, status TEXT);
            INSERT INTO thread_turns VALUES ('root',1,'completed'),('root',2,'inProgress');
            INSERT INTO thread_turns VALUES ('child',1,'inProgress');
            """)
        // Exercise the actual background monitor without constructing any view.
        let monitor = ConversationsModel(directory: directory)
        defer { monitor.stopMonitoring() }
        func waitUntil(_ label: String, _ predicate: () -> Bool) {
            let deadline = Date().addingTimeInterval(4)
            while !predicate() && Date() < deadline {
                _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            precondition(predicate(), "Background monitoring failed: \(label)")
        }
        waitUntil("initial read without a window") { monitor.conversations.count == 1 }
        precondition(monitor.conversations[0].children[0].status == .running)
        precondition(monitor.unreadCount == 0, "Existing children must not create notifications")
        let reader = CodexReader(directory: directory)
        var roots = try reader.load()
        precondition(roots.count == 1 && roots[0].title == "Conversation renommée")
        precondition(roots[0].status == .running)
        precondition(roots[0].children.count == 1)
        precondition(roots[0].children[0].title == "verification")
        precondition(roots[0].children[0].model == "gpt-5.6-luna")
        precondition(roots[0].children[0].effort == "max")
        precondition(roots[0].children[0].status == .running)
        precondition(roots[0].activeCount == 2)
        try fixture("thread_history_1.sqlite", "UPDATE thread_turns SET status='completed' WHERE thread_id='child';")
        waitUntil("completed child while panel is closed") {
            monitor.conversations.first?.children.first?.status == .completed
        }
        roots = try reader.load()
        precondition(roots[0].children[0].status == .completed, "Open edge must not mean running")
        precondition(roots[0].activeCount == 1)
        precondition(roots[0].filtered(showCompleted: false).first?.children.isEmpty == true)
        precondition(roots[0].filtered(showCompleted: true).first?.children.count == 1,
                     "Archived children must stay hidden even when completed tasks are shown")
        try fixture("thread_history_1.sqlite", "UPDATE thread_turns SET status='completed' WHERE thread_id='root';")
        let completed = try reader.load()[0]
        precondition(completed.filtered(showCompleted: false).isEmpty)
        try fixture("thread_history_1.sqlite", "UPDATE thread_turns SET status='inProgress' WHERE thread_id='child';")
        let parentOfActiveChild = try reader.load()[0]
        precondition(parentOfActiveChild.status == .completed)
        precondition(parentOfActiveChild.filtered(showCompleted: false).first?.parentTitle == "Conversation renommée",
                     "Promoted children must retain their original parent title")
        let link = parentOfActiveChild
        let validLink = Conversation(id: "00000000-0000-0000-0000-000000000001", title: "Link",
                                     model: "test", effort: "test", status: .running, createdAt: 0, children: [])
        precondition(validLink.codexURL?.absoluteString == "codex://threads/00000000-0000-0000-0000-000000000001",
                     "Task links must use the installed Codex thread route")
        precondition(link.codexURL == nil, "Invalid task IDs must not create navigation URLs")

        precondition(parentOfActiveChild.filtered(showCompleted: false).map(\.id) == ["child"],
                     "Hide completed parents while promoting their active children")
        precondition(parentOfActiveChild.filtered(showCompleted: true).first == parentOfActiveChild,
                     "Showing completed tasks must preserve the original hierarchy")
        for status in [RunStatus.completed, .interrupted, .failed, .running, .unknown] {
            let leaf = Conversation(id: "filter", title: "Filter", model: "test", effort: "test",
                                    status: status, createdAt: 0, children: [])
            let hidden = status == .completed || status == .interrupted || status == .failed
            precondition(leaf.filtered(showCompleted: false).isEmpty == hidden,
                         "Stopped tasks must be hidden; running and unknown tasks stay visible")
            precondition(leaf.filtered(showCompleted: true) == [leaf],
                         "The toggle must restore every non-archived status")
            var parent = leaf
            parent.children = parentOfActiveChild.children
            precondition(parent.filtered(showCompleted: false).map(\.id) == (hidden ? ["child"] : ["filter"]),
                         "Hidden parents must preserve active descendants for every stopped status")
        }
        try fixture("state_5.sqlite", "UPDATE threads SET archived=1 WHERE id='child';")
        waitUntil("archived child disappears live") {
            monitor.conversations.first?.children.isEmpty == true
        }
        let statePath = directory.appendingPathComponent("state_5.sqlite")
        let offlinePath = directory.appendingPathComponent("offline.sqlite")
        try FileManager.default.moveItem(at: statePath, to: offlinePath)
        waitUntil("read error is surfaced") { monitor.errorMessage != nil }
        try FileManager.default.moveItem(at: offlinePath, to: statePath)
        waitUntil("automatic recovery") { monitor.errorMessage == nil }
        let readonly = try ReadDatabase(directory.appendingPathComponent("state_5.sqlite"))
        do {
            _ = try readonly.rows("DELETE FROM threads")
            preconditionFailure("Reader allowed a write")
        } catch { /* Expected SQLITE_READONLY on the temporary fixture only. */ }
        try FileManager.default.removeItem(at: directory.appendingPathComponent("thread_history_1.sqlite"))
        let withoutHistory = try reader.load()
        precondition(withoutHistory[0].status == .unknown)
        precondition(RunStatus(stored: "unexpected") == .unknown)
        precondition(RunStatus(stored: "failed") == .failed)
        let launchTime = Int64(Date().timeIntervalSince1970 * 1000)
        for index in 1...4 {
            try fixture("state_5.sqlite", """
                INSERT INTO threads (id,name,archived,source,created_at_ms)
                VALUES ('new\(index)','New \(index)',0,'subagent',\(launchTime));
                INSERT INTO thread_spawn_edges VALUES ('root','new\(index)','open');
                """)
        }
        waitUntil("four newly launched children") { monitor.unreadCount == 4 }
        monitor.refresh()
        waitUntil("unchanged snapshot") { !monitor.isRefreshing }
        precondition(monitor.unreadCount == 4, "Each launch must be counted once")
        monitor.acknowledgeNewAgents()
        precondition(monitor.unreadCount == 0)
        try fixture("state_5.sqlite", """
            INSERT INTO threads (id,name,archived,source,created_at_ms)
            VALUES ('old-returned','Old returned',0,'subagent',1);
            INSERT INTO thread_spawn_edges VALUES ('root','old-returned','open');
            """)
        waitUntil("old history reappears") { monitor.conversations.first?.children.count == 5 }
        precondition(monitor.unreadCount == 0, "Old or acknowledged children must not notify again")
        try fixture("state_5.sqlite", """
            INSERT INTO threads (id,name,archived,source,created_at_ms)
            VALUES ('new5','New 5',0,'subagent',\(launchTime));
            INSERT INTO thread_spawn_edges VALUES ('root','new5','open');
            """)
        waitUntil("new launch after acknowledgement") { monitor.unreadCount == 1 }
        try fixture("state_5.sqlite", "UPDATE threads SET archived=1 WHERE id='new5';")
        waitUntil("archived notification disappears") { monitor.unreadCount == 0 }
        let legacyLog = directory.appendingPathComponent("legacy.jsonl")
        let lifecycle = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\"}}\n"
        let noise = "{\"type\":\"response_item\",\"payload\":{\"text\":\"" + String(repeating: "x", count: 70_000) + "\"}}\n"
        try (lifecycle + noise).write(to: legacyLog, atomically: true, encoding: .utf8)
        try """
            {"id":"legacy","thread_name":"First name"}
            {"id":"legacy","thread_name":"Renamed conversation"}
            {"partial":
            """.write(to: directory.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)
        try fixture("state_5.sqlite", """
            INSERT INTO threads (id,title,archived,source,history_mode,rollout_path)
            VALUES ('legacy','Original prompt',0,'vscode','legacy','\(legacyLog.path)');
            """)
        let legacy = try reader.load().first { $0.id == "legacy" }!
        precondition(legacy.title == "Renamed conversation")
        precondition(legacy.status == .completed, "Read lifecycle beyond a chunk boundary")
        precondition(legacy.filtered(showCompleted: false).isEmpty)
        // A paginated projection can remain on an older inProgress turn after a resume.
        let currentLog = directory.appendingPathComponent("current.jsonl")
        try (lifecycle + noise).write(to: currentLog, atomically: true, encoding: .utf8)
        try fixture("thread_history_1.sqlite", """
            CREATE TABLE thread_turns (thread_id TEXT, rollout_ordinal INTEGER, status TEXT);
            INSERT INTO thread_turns VALUES ('root',1,'completed'),('new1',1,'inProgress');
            """)
        try fixture("state_5.sqlite", """
            UPDATE threads SET rollout_path='\(currentLog.path)' WHERE id='new1';
            """)
        let reconciled = try reader.load()[0]
        precondition(reconciled.children.first { $0.id == "new1" }?.status == .completed,
                     "Paginated child completion must override a stale inProgress projection")
        precondition(reconciled.activeCount == 0, "Finished child must not inflate the running count")
        waitUntil("journal completion reaches the background monitor") { monitor.activeCount == 0 }
        try "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}\n"
            .write(to: currentLog, atomically: true, encoding: .utf8)
        waitUntil("journal restart reaches the background monitor") { monitor.activeCount == 1 }
        for timestamp in ["2026-09-07T15:00:00.000Z", "2026-09-07T15:00:00Z"] {
            let record: [String: Any] = ["type": "event_msg", "timestamp": timestamp,
                                         "payload": ["type": "task_started"]]
            try JSONSerialization.data(withJSONObject: record).write(to: currentLog)
            let timed = try reader.load()[0].children.first { $0.id == "new1" }!
            precondition(timed.turnStartedAt == Date(timeIntervalSince1970: 1_788_793_200),
                         "Current turn duration must use the journal start timestamp")
        }
        let resumedRecord: [String: Any] = ["type": "event_msg", "timestamp": "2026-09-07T15:01:00Z",
                                           "payload": ["type": "task_started"]]
        try JSONSerialization.data(withJSONObject: resumedRecord).write(to: currentLog)
        let resumed = try reader.load()[0].children.first { $0.id == "new1" }
        precondition(resumed?.turnStartedAt == Date(timeIntervalSince1970: 1_788_793_260),
                     "A new turn must reset its duration rather than reuse the previous start")
        try Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}".utf8).write(to: currentLog)
        let untimed = try reader.load()[0].children.first { $0.id == "new1" }
        precondition(untimed?.turnStartedAt == nil,
                     "Missing start timestamps must not invent a duration")
        for (event, expected) in [("turn_aborted", RunStatus.interrupted), ("task_failed", .failed)] {
            try "{\"type\":\"event_msg\",\"payload\":{\"type\":\"\(event)\"}}\n"
                .write(to: currentLog, atomically: true, encoding: .utf8)
            let child = try reader.load()[0].children.first { $0.id == "new1" }
            precondition(child?.status == expected, "Latest journal lifecycle must decide the child status")
            precondition(child?.turnStartedAt == nil, "Stopped turns must clear the running timer")
        }
        try FileManager.default.removeItem(at: currentLog)
        let fallback = try reader.load()[0].children.first { $0.id == "new1" }
        precondition(fallback?.status == .running, "Missing journal must preserve the database fallback")
        print("PASS: live models/states, legacy rename/status, archive/completed filters, recovery/read-only, new-agent badge 0→4→0→1→0")
    } catch {
        fputs("Checks failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

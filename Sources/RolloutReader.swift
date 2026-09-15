import Foundation

/// Used only by CodexReader's serial queue; retains lifecycle metadata, never transcript content.
final class RolloutReader {
    typealias Event = (status: RunStatus, startedAt: Date?)
    private var cache: [String: (attributes: NSDictionary, event: Event)] = [:]

    func retain(paths: Set<String>) {
        cache = cache.filter { paths.contains($0.key) }
    }

    func status(at url: URL) -> Event {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path) as NSDictionary
            // Symlink metadata does not describe changes to the target: always read it.
            let regularFile = attributes[FileAttributeKey.type] as? FileAttributeType == .typeRegular
            if regularFile, let cached = cache[url.path], cached.attributes.isEqual(attributes) {
                return cached.event
            }
            cache[url.path] = nil
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let event = try scan(file)
            let current = try FileManager.default.attributesOfItem(atPath: url.path) as NSDictionary
            // A writer may append, truncate or replace the journal while we read it.
            if regularFile && attributes.isEqual(current) {
                cache[url.path] = (attributes, event)
            }
            return event
        } catch {
            cache[url.path] = nil
            return (.unknown, nil)
        }
    }

    private func scan(_ file: FileHandle) throws -> Event {
        var offset = try file.seekToEnd()
        var fragments: [Data] = []

        func consume(_ fragment: Data) -> Event? {
            var line = fragment
            for suffix in fragments.reversed() { line.append(suffix) }
            fragments.removeAll(keepingCapacity: true)
            return Self.event(in: line)
        }

        while offset > 0 {
            let start = offset > 65_536 ? offset - 65_536 : 0
            try file.seek(toOffset: start)
            guard let block = try file.read(upToCount: Int(offset - start)),
                  block.count == Int(offset - start) else {
                throw CocoaError(.fileReadUnknown)
            }
            // Split each block once. Assemble a cross-block line only at its beginning;
            // repeatedly prepending and splitting the growing line made large logs quadratic.
            let event: Event? = block.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                var end = bytes.count
                for index in bytes.indices.reversed() where bytes[index] == 10 {
                    if let event = consume(Data(bytes[(index + 1)..<end])) { return event }
                    end = index
                }
                if start == 0 { return consume(Data(bytes[0..<end])) }
                fragments.append(Data(bytes[0..<end]))
                return nil
            }
            if let event { return event }
            offset = start
        }
        return (.unknown, nil)
    }

    private static func event(in line: Data) -> Event? {
        guard line.range(of: Data("\"event_msg\"".utf8)) != nil,
              let record = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              record["type"] as? String == "event_msg",
              let payload = record["payload"] as? [String: Any] else { return nil }
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
        default: return nil
        }
    }
}

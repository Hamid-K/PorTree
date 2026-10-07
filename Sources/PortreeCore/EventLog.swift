import Foundation

/// One row in the event log. Rows are generated from raw iterator drains
/// before the rescan debounce, so bounce storms coalesce the rescan but never
/// silently vanish from the log.
public struct EventRow: Sendable, Codable, Identifiable, Hashable {
    public enum Kind: String, Sendable, Codable {
        case connected, disconnected, reenumerated, rescan, info, export
    }

    public let id: UUID
    public var date: Date
    public let kind: Kind
    public let title: String
    public let detail: String
    public let nodeID: UInt64?
    /// Flood coalescing: a device flapping repeats as one row with ×N.
    public var count: Int

    public init(kind: Kind, title: String, detail: String, nodeID: UInt64? = nil, date: Date = Date()) {
        self.id = UUID()
        self.date = date
        self.kind = kind
        self.title = title
        self.detail = detail
        self.nodeID = nodeID
        self.count = 1
    }
}

/// Appends event rows as JSONL under Application Support/Portree, rotating at
/// 5 MB (one previous file kept). Writes happen on a background queue; losing
/// a row on crash is acceptable, blocking the UI is not.
public final class EventLogWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "portree.eventlog", qos: .utility)
    private let encoder = JSONEncoder()
    private var appendsSinceCheck = 0

    public let fileURL: URL

    public init?() {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = support.appendingPathComponent("Portree", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        fileURL = dir.appendingPathComponent("events.jsonl")
        encoder.dateEncodingStrategy = .iso8601
    }

    public func append(_ row: EventRow) {
        queue.async { [self] in
            guard var data = try? encoder.encode(row) else { return }
            data.append(Data("\n".utf8))
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
            appendsSinceCheck += 1
            if appendsSinceCheck >= 100 {
                appendsSinceCheck = 0
                rotateIfNeeded()
            }
        }
    }

    private func rotateIfNeeded() {
        let size = ((try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? Int) ?? 0
        guard size > 5_000_000 else { return }
        let rotated = fileURL.deletingPathExtension().appendingPathExtension("jsonl.1")
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: fileURL, to: rotated)
    }
}

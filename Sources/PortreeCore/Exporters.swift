import Foundation

public enum Exporters {

    /// Pretty-printed JSON of the full snapshot — every node with its complete
    /// raw property bag (OSData blobs as base64).
    public static func json(_ snapshot: Snapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(snapshot)
    }

    /// Writes a timestamped snapshot into `directory` and returns the URL.
    @discardableResult
    public static func writeSnapshot(_ snapshot: Snapshot, to directory: URL) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = directory.appendingPathComponent("portree-snapshot-\(formatter.string(from: snapshot.takenAt)).json")
        try json(snapshot).write(to: url)
        return url
    }
}

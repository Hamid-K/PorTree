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

    /// Inverse of `json(_:)` — loads a snapshot exported by --dump or the
    /// baseline save (used by --from-snapshot to render saved topologies).
    public static func decodeSnapshot(_ data: Data) throws -> Snapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Snapshot.self, from: data)
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

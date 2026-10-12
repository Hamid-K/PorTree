import Foundation

/// GitHub release notes are markdown. The update panel renders them as
/// blocks — headings, bullets, quotes, paragraphs — with inline markdown
/// (bold, code, links) handled per block by the UI.
public enum ReleaseNotes {

    public enum Block: Sendable, Hashable {
        case heading(String)
        case bullet(String)
        case quote(String)
        case paragraph(String)
    }

    public static func blocks(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if let heading = strip(line, prefixes: ["### ", "## ", "# "]) {
                blocks.append(.heading(heading))
            } else if let bullet = strip(line, prefixes: ["- ", "* ", "+ "]) {
                blocks.append(.bullet(bullet))
            } else if let quote = strip(line, prefixes: ["> ", ">"]) {
                blocks.append(.quote(quote))
            } else if case .paragraph(let previous)? = blocks.last {
                // Soft-wrapped paragraph lines join into one paragraph.
                blocks[blocks.count - 1] = .paragraph(previous + " " + line)
            } else {
                blocks.append(.paragraph(line))
            }
        }
        return blocks
    }

    private static func strip(_ line: String, prefixes: [String]) -> String? {
        for prefix in prefixes where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}

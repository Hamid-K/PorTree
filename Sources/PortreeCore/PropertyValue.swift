import Foundation
import CoreFoundation

/// A Sendable, Codable mirror of an IORegistry property value.
/// `[String: Any]` cannot legally cross from the IOKit queue to the MainActor
/// under Swift 6, so conversion happens at read time on the IOKit queue.
/// OSData blobs export as base64 (Codable), and render as hex in the UI.
public enum PropertyValue: Sendable, Hashable, Codable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case data(Data)
    case array([PropertyValue])
    case dict([String: PropertyValue])

    public init?(cf: AnyObject) {
        switch CFGetTypeID(cf) {
        case CFStringGetTypeID():
            self = .string(cf as! String)
        case CFBooleanGetTypeID():
            self = .bool(CFBooleanGetValue((cf as! CFBoolean)))
        case CFNumberGetTypeID():
            let num = cf as! CFNumber
            if CFNumberIsFloatType(num) {
                var d = 0.0
                CFNumberGetValue(num, .doubleType, &d)
                self = .double(d)
            } else {
                var i: Int64 = 0
                CFNumberGetValue(num, .sInt64Type, &i)
                self = .int(i)
            }
        case CFDataGetTypeID():
            self = .data(cf as! Data)
        case CFArrayGetTypeID():
            self = .array((cf as! [AnyObject]).compactMap { PropertyValue(cf: $0) })
        case CFDictionaryGetTypeID():
            guard let d = cf as? [String: AnyObject] else { return nil }
            self = .dict(d.compactMapValues { PropertyValue(cf: $0) })
        default:
            return nil
        }
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var intValue: Int64? {
        switch self {
        case .int(let i): return i
        case .double(let d): return Int64(d)
        default: return nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        // IORegistry booleans sometimes surface as "Yes"/"No" strings.
        if case .string(let s) = self { return s == "Yes" ? true : (s == "No" ? false : nil) }
        return nil
    }

    public var dataValue: Data? {
        if case .data(let d) = self { return d }
        return nil
    }

    public var dictValue: [String: PropertyValue]? {
        if case .dict(let d) = self { return d }
        return nil
    }

    public var arrayValue: [PropertyValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var typeName: String {
        switch self {
        case .string: return "String"
        case .int: return "Number"
        case .double: return "Number (float)"
        case .bool: return "Boolean"
        case .data(let d): return "Data ⟨\(d.count) B⟩"
        case .array(let a): return "Array (\(a.count))"
        case .dict(let d): return "Dictionary (\(d.count))"
        }
    }

    /// One-line rendering for the Raw property table.
    public var displayString: String {
        switch self {
        case .string(let s): return "\"\(s)\""
        case .int(let i): return "\(i)"
        case .double(let d): return "\(d)"
        case .bool(let b): return b ? "Yes" : "No"
        case .data(let d):
            let head = d.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
            return d.count > 16 ? "⟨\(head) … \(d.count) B⟩" : "⟨\(head)⟩"
        case .array(let a): return "[" + a.prefix(8).map(\.displayString).joined(separator: ", ") + (a.count > 8 ? ", …]" : "]")
        case .dict(let d): return "{" + d.keys.sorted().prefix(6).joined(separator: ", ") + (d.count > 6 ? ", …}" : "}")
        }
    }
}

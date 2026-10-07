import Foundation
import IOKit

/// Thin wrappers over the IOKit registry C API. Reading the registry needs no
/// entitlements, sandbox exceptions, or TCC approval (verified on macOS 27
/// with an unsigned CLT-only build). All calls are expected to run on the
/// dedicated IOKit queue; io_object_t handles never cross threads.
public enum Registry {

    public static func rootEntry() -> io_registry_entry_t {
        IORegistryGetRootEntry(kIOMainPortDefault)
    }

    /// Children of `entry` in `plane`. Caller must IOObjectRelease each child.
    public static func children(of entry: io_registry_entry_t, plane: String) -> [io_registry_entry_t] {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, plane, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [io_registry_entry_t] = []
        while true {
            let child = IOIteratorNext(iterator)
            if child == 0 { break }
            result.append(child)
        }
        return result
    }

    public static func name(of entry: io_registry_entry_t) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetName(entry, &buffer) == KERN_SUCCESS else { return "" }
        let bytes = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    public static func className(of entry: io_object_t) -> String {
        guard let cf = IOObjectCopyClass(entry) else { return "" }
        return cf.takeRetainedValue() as String
    }

    public static func entryID(of entry: io_registry_entry_t) -> UInt64 {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(entry, &id)
        return id
    }

    /// All properties in one call, converted to Sendable values on the spot.
    public static func properties(of entry: io_registry_entry_t) -> [String: PropertyValue] {
        var dict: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &dict, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let cf = dict?.takeRetainedValue(),
              let swiftDict = cf as? [String: AnyObject] else { return [:] }
        var out: [String: PropertyValue] = [:]
        out.reserveCapacity(swiftDict.count)
        for (key, value) in swiftDict {
            out[key] = PropertyValue(cf: value) ?? .string(String(describing: value))
        }
        return out
    }

    public static func conforms(_ entry: io_object_t, to className: String) -> Bool {
        IOObjectConformsTo(entry, className) != 0
    }

    /// All services matching a class (base-class matching: concrete
    /// Thunderbolt classes vary per device). Caller releases each.
    public static func matchingServices(_ className: String) -> [io_object_t] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var result: [io_object_t] = []
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            result.append(service)
        }
        return result
    }
}

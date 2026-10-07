import Foundation
import IOKit

/// One physical monitor as the port-transport subsystem sees it: an
/// IOPortTransportStateDisplayPort entry holding the sink's EDID identity.
/// This is the registry's own record of "a display is receiving video on
/// this DP tunnel" — including monitors that are electrically invisible to
/// the USB/TB topology (plain DP sinks behind a TB→DP adapter).
///
/// The EDID triple (vendor, product, serial) is the same identity that
/// CoreGraphics reports per screen (CGDisplayVendorNumber / ModelNumber /
/// SerialNumber), so sinks and live screens join deterministically by ID,
/// not by name.
public struct DisplaySink: Sendable, Hashable, Codable {
    public let name: String
    /// EDID legacy manufacturer ID (e.g. 4268 = DEL) when published.
    public let edidVendorID: Int64?
    public let edidProductID: Int64?
    public let edidSerial: Int64?
    /// Negotiated DP link, e.g. "5.4 Gbps (HBR2)".
    public let linkRate: String?
    public let active: Bool

    public init(name: String, edidVendorID: Int64?, edidProductID: Int64?, edidSerial: Int64?, linkRate: String?, active: Bool) {
        self.name = name
        self.edidVendorID = edidVendorID
        self.edidProductID = edidProductID
        self.edidSerial = edidSerial
        self.linkRate = linkRate
        self.active = active
    }
}

public enum DisplaySinks {

    /// All DisplayPort sinks currently known to the port-transport state
    /// tree. Entries without a ProductName are tunnels with nothing attached.
    public static func enumerate() -> [DisplaySink] {
        Registry.matchingServices("IOPortTransportStateDisplayPort").compactMap { service in
            defer { IOObjectRelease(service) }
            let props = Registry.properties(of: service)
            guard let name = props["ProductName"]?.stringValue, !name.isEmpty else { return nil }
            // EDID vendor lives inside Metadata on some OS builds; ProductID
            // and SerialNumber are mirrored at the top level.
            return DisplaySink(
                name: name,
                edidVendorID: props["VendorID"]?.intValue,
                edidProductID: props["ProductID"]?.intValue,
                edidSerial: props["SerialNumber"]?.intValue,
                linkRate: props["LinkRateDescription"]?.stringValue,
                active: props["Active"]?.boolValue ?? true
            )
        }
    }
}

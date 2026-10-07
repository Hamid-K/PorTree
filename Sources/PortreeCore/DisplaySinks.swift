import Foundation
import IOKit

/// One physical monitor as the port-transport subsystem sees it: an
/// IOPortTransportStateDisplayPort registry entry holding the sink's EDID
/// identity. This is the registry's own record of "a display is receiving
/// video on this port" — including monitors that are electrically invisible
/// to the USB/TB topology (plain DP/HDMI sinks behind a TB→DP adapter).
///
/// The EDID pair (product, serial) is the same identity CoreGraphics reports
/// per screen (CGDisplayModelNumber / CGDisplaySerialNumber), so sinks and
/// live screens join deterministically by ID, not by name.
public struct DisplaySink: Sendable, Hashable, Codable {
    /// The sink's own IORegistry entry ID — real, stable for the entry's
    /// life, and usable as a graph-node ID.
    public let registryID: UInt64
    public let name: String
    public let edidProductID: Int64?
    public let edidSerial: Int64?
    /// Negotiated DP link, e.g. "5.4 Gbps (HBR2)".
    public let linkRate: String?
    public let laneCount: Int64?
    /// The sink-side connector as the DP DPCD reports it, verbatim from the
    /// registry ("DP", "HDMI", "VGA", …).
    public let downstreamType: String?
    /// True when the video rides a TB/USB4 tunnel (vs a built-in port).
    public let tunneled: Bool
    /// Physical Mac receptacle number this sink's video leaves through.
    public let receptacle: Int64?
    public let active: Bool
    /// Full property bag for the inspector's Raw tab.
    public let properties: [String: PropertyValue]

    public init(
        registryID: UInt64, name: String, edidProductID: Int64?, edidSerial: Int64?,
        linkRate: String?, laneCount: Int64?, downstreamType: String?, tunneled: Bool,
        receptacle: Int64?, active: Bool, properties: [String: PropertyValue] = [:]
    ) {
        self.registryID = registryID
        self.name = name
        self.edidProductID = edidProductID
        self.edidSerial = edidSerial
        self.linkRate = linkRate
        self.laneCount = laneCount
        self.downstreamType = downstreamType
        self.tunneled = tunneled
        self.receptacle = receptacle
        self.active = active
        self.properties = properties
    }
}

public enum DisplaySinks {

    /// All DisplayPort sinks with a display attached. Entries without a
    /// ProductName are ports with nothing connected (e.g. the built-in HDMI
    /// port publishes a permanent inactive entry) and are skipped.
    public static func enumerate() -> [DisplaySink] {
        Registry.matchingServices("IOPortTransportStateDisplayPort").compactMap { service in
            defer { IOObjectRelease(service) }
            let props = Registry.properties(of: service)
            guard let name = props["ProductName"]?.stringValue, !name.isEmpty else { return nil }
            let metadata = props["Metadata"]?.dictValue ?? [:]
            return DisplaySink(
                registryID: Registry.entryID(of: service),
                name: name,
                edidProductID: props["ProductID"]?.intValue,
                edidSerial: props["SerialNumber"]?.intValue,
                linkRate: props["LinkRateDescription"]?.stringValue,
                laneCount: props["LaneCount"]?.intValue,
                downstreamType: metadata["DFP Type Description"]?.stringValue,
                tunneled: props["Tunneled"]?.boolValue ?? false,
                receptacle: props["ParentBuiltInPortNumber"]?.intValue,
                active: props["Active"]?.boolValue ?? true,
                properties: props
            )
        }
    }
}

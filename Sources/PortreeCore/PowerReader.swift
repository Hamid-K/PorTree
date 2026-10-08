import Foundation
import IOKit

/// The Mac's power-input state from AppleSmartBattery: the negotiated
/// adapter contract, the source's advertised menu, and LIVE measured input
/// power from the SMC telemetry — labeled "input power", never "charging"
/// (the Mac draws from the adapter even when IsCharging is false).
public struct PowerInfo: Sendable, Hashable, Codable {
    public let externalConnected: Bool
    public let isCharging: Bool
    /// Apple's own adapter description, verbatim (e.g. "pd charger").
    public let adapterDescription: String?
    public let adapterWatts: Int64?
    public let adapterVoltageMV: Int64?
    public let adapterCurrentMA: Int64?
    public let isWireless: Bool
    /// The source's advertised PD levels (AdapterDetails.UsbHvcMenu) and
    /// which one is negotiated.
    public let hvcMenu: [PDO]
    public let hvcIndex: Int64?
    /// Live measured system input power / load / battery flow, in mW
    /// (PowerTelemetryData — SMC measurements, not estimates).
    public let systemPowerInMW: Int64?
    public let systemLoadMW: Int64?
    public let batteryPowerMW: Int64?
    /// Per-port PD partner facts (FedDetails): who can power the Mac.
    public let sources: [FedSource]

    public struct FedSource: Sendable, Hashable, Codable {
        public let vendorID: Int64
        public let productID: Int64
        public let dualRolePower: Bool
        public let pdRevision: Int64?
        public let externalConnected: Bool
    }

    public init(
        externalConnected: Bool, isCharging: Bool, adapterDescription: String?,
        adapterWatts: Int64?, adapterVoltageMV: Int64?, adapterCurrentMA: Int64?,
        isWireless: Bool, hvcMenu: [PDO], hvcIndex: Int64?,
        systemPowerInMW: Int64?, systemLoadMW: Int64?, batteryPowerMW: Int64?,
        sources: [FedSource]
    ) {
        self.externalConnected = externalConnected
        self.isCharging = isCharging
        self.adapterDescription = adapterDescription
        self.adapterWatts = adapterWatts
        self.adapterVoltageMV = adapterVoltageMV
        self.adapterCurrentMA = adapterCurrentMA
        self.isWireless = isWireless
        self.hvcMenu = hvcMenu
        self.hvcIndex = hvcIndex
        self.systemPowerInMW = systemPowerInMW
        self.systemLoadMW = systemLoadMW
        self.batteryPowerMW = batteryPowerMW
        self.sources = sources
    }
}

public enum PowerReader {

    public static func read() -> PowerInfo? {
        let services = Registry.matchingServices("AppleSmartBattery")
        defer { services.forEach { IOObjectRelease($0) } }
        guard let battery = services.first else { return nil }
        let props = Registry.properties(of: battery)

        let adapter = props["AdapterDetails"]?.dictValue ?? [:]
        let telemetry = props["PowerTelemetryData"]?.dictValue ?? [:]

        let menu: [PDO] = (adapter["UsbHvcMenu"]?.arrayValue ?? []).compactMap { entry in
            guard let dict = entry.dictValue, let voltage = dict["MaxVoltage"]?.intValue else { return nil }
            let current = dict["MaxCurrent"]?.intValue ?? 0
            return PDO(voltageMV: voltage, maxCurrentMA: current, maxPowerMW: voltage * current / 1000)
        }

        let sources: [PowerInfo.FedSource] = (props["FedDetails"]?.arrayValue ?? []).compactMap { entry in
            guard let dict = entry.dictValue,
                  let vid = dict["FedVendorID"]?.intValue, vid != 0,
                  let pid = dict["FedProductID"]?.intValue else { return nil }
            return PowerInfo.FedSource(
                vendorID: vid,
                productID: pid,
                dualRolePower: dict["FedDualRolePower"]?.intValue == 1,
                pdRevision: dict["FedPdSpecRevision"]?.intValue,
                externalConnected: dict["FedExternalConnected"]?.intValue == 1
            )
        }

        return PowerInfo(
            externalConnected: props["ExternalConnected"]?.boolValue ?? false,
            isCharging: props["IsCharging"]?.boolValue ?? false,
            adapterDescription: adapter["Description"]?.stringValue,
            adapterWatts: adapter["Watts"]?.intValue,
            adapterVoltageMV: adapter["AdapterVoltage"]?.intValue,
            adapterCurrentMA: adapter["Current"]?.intValue,
            isWireless: adapter["IsWireless"]?.boolValue ?? false,
            hvcMenu: menu,
            hvcIndex: adapter["UsbHvcHvcIndex"]?.intValue,
            systemPowerInMW: telemetry["SystemPowerIn"]?.intValue,
            systemLoadMW: telemetry["SystemLoad"]?.intValue,
            batteryPowerMW: telemetry["BatteryPower"]?.intValue,
            sources: sources
        )
    }
}

import Foundation
@testable import PortreeCore

/// Compact synthetic-node builder for logic tests. Only the fields a given
/// rule reads need to be set.
func fixture(
    id: UInt64,
    name: String = "dev",
    kind: NodeKind = .usbDevice,
    deviceClass: Int64? = nil,
    protocolCode: Int64? = nil,
    vid: Int64? = nil,
    pid: Int64? = nil,
    serial: String? = nil,
    bps: Int64 = 0,
    bcdUSB: Int64? = nil,
    location: Int64? = nil,
    container: String? = nil,
    powerMA: Int64? = nil,
    extra: [String: PropertyValue] = [:],
    children: [DeviceNode] = []
) -> DeviceNode {
    var props: [String: PropertyValue] = extra
    if let deviceClass { props["bDeviceClass"] = .int(deviceClass) }
    if let protocolCode { props["bDeviceProtocol"] = .int(protocolCode) }
    if let vid { props["idVendor"] = .int(vid) }
    if let pid { props["idProduct"] = .int(pid) }
    if let serial { props["USB Serial Number"] = .string(serial) }
    if bps > 0 { props["UsbLinkSpeed"] = .int(bps) }
    if let bcdUSB { props["bcdUSB"] = .int(bcdUSB) }
    if let location { props["locationID"] = .int(location) }
    if let container { props["kUSBContainerID"] = .string(container) }
    if let powerMA { props["UsbPowerSinkAllocation"] = .int(powerMA) }
    return DeviceNode(
        id: id,
        kind: kind,
        name: name,
        subtitle: "",
        className: kind == .usbController ? "TestXHCI" : "IOUSBHostDevice",
        category: deviceClass == 9 ? .hub : .unknown,
        tier: Format.tier(forBps: bps),
        speedLabel: Format.speedLabel(bps: bps),
        linkSpeedBps: bps,
        properties: props,
        children: children
    )
}

func controller(id: UInt64, tierLimit: Int64 = 6, children: [DeviceNode]) -> DeviceNode {
    fixture(
        id: id, name: "Controller", kind: .usbController,
        extra: ["UsbHostControllerTierLimit": .int(tierLimit)],
        children: children
    )
}

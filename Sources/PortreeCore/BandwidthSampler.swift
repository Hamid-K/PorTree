import Foundation
import IOKit

/// Live throughput sampling for record mode. Honesty rule: only sources with
/// real byte counters are sampled — storage devices (IOBlockStorageDriver
/// Statistics), and network interfaces (getifaddrs byte counters) mapped back
/// to their USB/PCI ancestor. Nodes without counters simply have no series;
/// nothing is estimated. Zero polling happens while stopped.
public final class BandwidthSampler: @unchecked Sendable {

    /// bytes/second per node ID, delivered once per second on an internal queue.
    public typealias Handler = @Sendable ([UInt64: Double], Date) -> Void

    private let queue = DispatchQueue(label: "portree.sampler", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let onSample: Handler

    // Keyed by the DRIVER's entry ID (not the attributed node): two storage
    // drivers under one device must not overwrite each other's baseline.
    private var lastStorage: [UInt64: (node: UInt64, total: Int64)] = [:]
    private var lastNIC: [String: (node: UInt64, total: UInt64)] = [:]
    private var lastDate: Date?

    public init(onSample: @escaping Handler) {
        self.onSample = onSample
    }

    public func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            lastStorage = [:]
            lastNIC = [:]
            lastDate = nil
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + 1, repeating: 1.0)
            source.setEventHandler { [weak self] in self?.sample() }
            source.resume()
            timer = source
        }
    }

    public func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
        }
    }

    private func sample() {
        let now = Date()
        let elapsed = lastDate.map { now.timeIntervalSince($0) } ?? 1.0
        lastDate = now
        guard elapsed > 0.1 else { return }

        var rates: [UInt64: Double] = [:]

        // Storage: bytes read+written per IOBlockStorageDriver, attributed to
        // the USB device or tunneled PCI device above it.
        let drivers = Registry.matchingServices("IOBlockStorageDriver")
        defer { drivers.forEach { IOObjectRelease($0) } }
        for driver in drivers {
            guard case .dict(let stats)? = Registry.properties(of: driver)["Statistics"] else { continue }
            let total = (stats["Bytes (Read)"]?.intValue ?? 0) + (stats["Bytes (Write)"]?.intValue ?? 0)
            guard total > 0,
                  // Nearest ancestor wins: USB storage → the USB device node,
                  // NVMe → the IONVMeController node (internal or enclosure).
                  let nodeID = Registry.ancestorID(of: driver, conformingToAny: ["IOUSBHostDevice", "IONVMeController", "IOPCIDevice"])
            else { continue }
            let driverID = Registry.entryID(of: driver)
            if let previous = lastStorage[driverID], previous.node == nodeID, total >= previous.total {
                rates[nodeID, default: 0] += Double(total - previous.total) / elapsed
            }
            lastStorage[driverID] = (nodeID, total)
        }

        // Network: interface byte counters mapped via IONetworkInterface's
        // BSD Name to the USB/PCI ancestor (e.g. the Realtek 2.5G LAN).
        var nodeForBSDName: [String: UInt64] = [:]
        let interfaces = Registry.matchingServices("IONetworkInterface")
        defer { interfaces.forEach { IOObjectRelease($0) } }
        for interface in interfaces {
            guard let bsdName = Registry.properties(of: interface)["BSD Name"]?.stringValue,
                  let nodeID = Registry.ancestorID(of: interface, conformingToAny: ["IOUSBHostDevice", "IOPCIDevice"])
            else { continue }
            nodeForBSDName[bsdName] = nodeID
        }

        for (name, total) in interfaceByteTotals() {
            guard let nodeID = nodeForBSDName[name] else { continue }
            if let previous = lastNIC[name], previous.node == nodeID {
                // if_data counters are 32-bit and wrap; delta modulo 2^32.
                let delta = (total &- previous.total) & 0xFFFF_FFFF
                rates[nodeID, default: 0] += Double(delta) / elapsed
            }
            lastNIC[name] = (nodeID, total)
        }

        onSample(rates, now)
    }

    /// BSD interface name → in+out byte total, via getifaddrs/AF_LINK.
    private func interfaceByteTotals() -> [String: UInt64] {
        var totals: [String: UInt64] = [:]
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return totals }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let entry = current.pointee
            if let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
               let dataPointer = entry.ifa_data {
                let data = dataPointer.assumingMemoryBound(to: if_data.self).pointee
                let name = String(cString: entry.ifa_name)
                totals[name] = UInt64(data.ifi_ibytes) &+ UInt64(data.ifi_obytes)
            }
            cursor = entry.ifa_next
        }
        return totals
    }
}

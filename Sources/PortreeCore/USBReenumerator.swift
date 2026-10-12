import Foundation
import IOKit
import IOUSBHost

/// Software unplug/replug: IOUSBHostDevice.reset() terminates the device's
/// registry entry and re-enumerates it — the kernel equivalent of pulling
/// the cable. Needs exclusive ownership of the device; interface-level
/// drivers (HID, NCM, storage) don't hold the DEVICE open, so this works
/// unprivileged for most peripherals. Hub drivers DO refuse to release
/// (kIOReturnExclusiveAccess) — hubs cannot be reset without root, and we
/// say so instead of pretending.
public enum USBReenumerator {

    public enum Outcome: Sendable {
        case reenumerated
        /// The kernel owner refused to let go — typical for hubs.
        case exclusiveAccess
        case failed(String)
    }

    public static func reenumerate(entryID: UInt64) -> Outcome {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IORegistryEntryIDMatching(entryID)
        )
        guard service != 0 else { return .failed("device is no longer in the registry") }
        defer { IOObjectRelease(service) }

        func attempt(_ options: IOUSBHostObjectInitOptions) -> Outcome? {
            do {
                let device = try IOUSBHostDevice(
                    __ioService: service, options: options, queue: nil, interestHandler: nil
                )
                try device.reset()
                // The user client dies with the reset — never reuse it.
                return .reenumerated
            } catch {
                let code = UInt32(bitPattern: Int32((error as NSError).code))
                if code == 0xE000_02C5 { return nil }  // kIOReturnExclusiveAccess → caller may retry
                return .failed((error as NSError).localizedDescription)
            }
        }

        if let outcome = attempt([]) { return outcome }
        // Politely ask the current owner to close (DeviceSeize), then accept
        // the refusal honestly.
        if let outcome = attempt(.deviceSeize) { return outcome }
        return .exclusiveAccess
    }
}

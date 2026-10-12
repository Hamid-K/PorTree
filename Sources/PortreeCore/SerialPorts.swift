import Foundation
import IOKit
import Darwin

/// One serial port as macOS publishes it (IOSerialBSDClient): CDC-ACM
/// devices, FTDI / CP210x / CH340 / PL2303 UART bridges and every other
/// serial driver all surface the same node — detection is generic, no
/// vendor table.
public struct SerialPort: Sendable, Hashable, Codable, Identifiable {
    public var id: String { calloutPath }
    /// /dev/cu.* — the "call out" device an app opens to talk to the port.
    public let calloutPath: String
    public let dialinPath: String?
    public let baseName: String
    /// The USB device that owns this port; nil for built-in ports
    /// (debug-console, Bluetooth-Incoming-Port).
    public let usbEntryID: UInt64?
    /// The kernel driver class serving the port (e.g. AppleUSBACMData,
    /// AppleUSBFTDI) — tells CDC-ACM from vendor UART bridges.
    public let driverClass: String?

    public init(calloutPath: String, dialinPath: String?, baseName: String, usbEntryID: UInt64?, driverClass: String?) {
        self.calloutPath = calloutPath
        self.dialinPath = dialinPath
        self.baseName = baseName
        self.usbEntryID = usbEntryID
        self.driverClass = driverClass
    }
}

public enum SerialPorts {

    public static func enumerate() -> [SerialPort] {
        Registry.matchingServices("IOSerialBSDClient").compactMap { service in
            defer { IOObjectRelease(service) }
            let props = Registry.properties(of: service)
            guard let callout = props["IOCalloutDevice"]?.stringValue else { return nil }
            var driver: String?
            var parent: io_registry_entry_t = 0
            if IORegistryEntryGetParentEntry(service, "IOService", &parent) == KERN_SUCCESS, parent != 0 {
                driver = Registry.className(of: parent)
                IOObjectRelease(parent)
            }
            return SerialPort(
                calloutPath: callout,
                dialinPath: props["IODialinDevice"]?.stringValue,
                baseName: props["IOTTYBaseName"]?.stringValue ?? callout,
                usbEntryID: Registry.ancestorID(of: service, conformingToAny: ["IOUSBHostDevice"]),
                driverClass: driver
            )
        }
        .sorted { $0.calloutPath < $1.calloutPath }
    }
}

/// A raw serial session on a /dev/cu.* port: 8N1, no flow control, chosen
/// baud. Exclusive (TIOCEXCL) so another app can't interleave on the line.
/// All fd work happens on a private queue; data and close events are
/// delivered through the callbacks.
public final class SerialConnection: @unchecked Sendable {

    public enum Failure: Error, LocalizedError {
        case open(String, Int32)
        case configure(String)

        public var errorDescription: String? {
            switch self {
            case .open(let path, let code):
                let reason = code == EBUSY
                    ? "port is busy — another app has it open"
                    : String(cString: strerror(code))
                return "could not open \(path): \(reason)"
            case .configure(let message):
                return message
            }
        }
    }

    public let path: String
    private let queue = DispatchQueue(label: "portree.serial")

    /// Ports this process has open. TIOCEXCL keeps OTHER apps off a real
    /// serial device, but not every tty honors it (macOS ptys don't), so
    /// PorTree also refuses to open the same port twice itself.
    private static let openLock = NSLock()
    nonisolated(unsafe) private static var openPaths: Set<String> = []

    private static func claim(_ path: String) -> Bool {
        openLock.lock()
        defer { openLock.unlock() }
        return openPaths.insert(path).inserted
    }

    private static func release(_ path: String) {
        openLock.lock()
        openPaths.remove(path)
        openLock.unlock()
    }
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?

    public init(path: String) {
        self.path = path
    }

    /// Opens and configures the port. Opening asserts DTR — Arduino-style
    /// boards reset on connect; that is how they are designed.
    public func open(
        baud: Int,
        onData: @escaping @Sendable (Data) -> Void,
        onClose: @escaping @Sendable () -> Void
    ) throws {
        guard Self.claim(path) else { throw Failure.open(path, EBUSY) }
        var claimed = true
        defer { if claimed { Self.release(path) } }

        let descriptor = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard descriptor >= 0 else { throw Failure.open(path, errno) }
        if ioctl(descriptor, TIOCEXCL) != 0 {
            let code = errno
            Darwin.close(descriptor)
            throw Failure.open(path, code)
        }

        var settings = termios()
        guard tcgetattr(descriptor, &settings) == 0 else {
            Darwin.close(descriptor)
            throw Failure.configure("could not read port settings")
        }
        cfmakeraw(&settings)
        settings.c_cflag |= tcflag_t(CS8 | CLOCAL | CREAD)
        settings.c_cflag &= ~tcflag_t(PARENB | CSTOPB | CRTSCTS)
        // Standard rates go through termios; macOS needs IOSSIOSPEED for
        // anything above 230400.
        let termiosRate = baud <= 230_400 ? speed_t(baud) : speed_t(9_600)
        cfsetspeed(&settings, termiosRate)
        guard tcsetattr(descriptor, TCSANOW, &settings) == 0 else {
            Darwin.close(descriptor)
            throw Failure.configure("port rejected the settings (8N1 @ \(baud))")
        }
        if baud > 230_400 {
            var rate = speed_t(baud)
            let IOSSIOSPEED: UInt = 0x8008_5402  // _IOW('T', 2, speed_t)
            guard ioctl(descriptor, IOSSIOSPEED, &rate) == 0 else {
                Darwin.close(descriptor)
                throw Failure.configure("port rejected \(baud) baud")
            }
        }

        fd = descriptor
        let readSource = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        readSource.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = read(self.fd, &buffer, buffer.count)
            if count > 0 {
                onData(Data(buffer[0..<count]))
            } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                // EOF or a hard error: the device went away.
                self.source?.cancel()
            }
        }
        let claimedPath = path
        readSource.setCancelHandler { [weak self] in
            if let self {
                if self.fd >= 0 { Darwin.close(self.fd) }
                self.fd = -1
            }
            Self.release(claimedPath)
            onClose()
        }
        source = readSource
        claimed = false  // ownership of the claim moves to the cancel handler
        readSource.resume()
    }

    public func send(_ data: Data) {
        queue.async { [weak self] in
            guard let self, self.fd >= 0 else { return }
            data.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                _ = write(self.fd, base, buffer.count)
            }
        }
    }

    public func close() {
        queue.async { [weak self] in self?.source?.cancel() }
    }
}

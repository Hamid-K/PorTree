import Testing
import Foundation
import Darwin
@testable import PortreeCore

private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    let signal = DispatchSemaphore(value: 0)

    func append(_ data: Data) {
        lock.lock()
        buffer.append(data)
        lock.unlock()
        signal.signal()
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}

@Suite struct SerialTests {

    /// A pseudo-terminal pair is a real TTY: the connection's open, TIOCEXCL,
    /// termios and dispatch-read paths run exactly as on a USB serial port.
    @Test func ptyRoundTrip() throws {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        try #require(master >= 0)
        defer { close(master) }
        try #require(grantpt(master) == 0 && unlockpt(master) == 0)
        let path = String(cString: ptsname(master))

        let collector = Collector()
        let connection = SerialConnection(path: path)
        try connection.open(baud: 115_200, onData: { collector.append($0) }, onClose: {})
        defer { connection.close() }

        // Device → host.
        let hello = Array("hello\n".utf8)
        #expect(write(master, hello, hello.count) == hello.count)
        let deadline = Date().addingTimeInterval(3)
        while collector.value.count < hello.count, Date() < deadline {
            _ = collector.signal.wait(timeout: .now() + 0.2)
        }
        #expect(collector.value == Data(hello))

        // Host → device.
        connection.send(Data("ping".utf8))
        var received = Data()
        var fds = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
        let readDeadline = Date().addingTimeInterval(3)
        while received.count < 4, Date() < readDeadline {
            if poll(&fds, 1, 200) > 0 {
                var buffer = [UInt8](repeating: 0, count: 64)
                let count = read(master, &buffer, buffer.count)
                if count > 0 { received.append(contentsOf: buffer[0..<count]) }
            }
        }
        #expect(received == Data("ping".utf8))
    }

    @Test func secondOpenOfSamePortIsRefused() throws {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        try #require(master >= 0)
        defer { close(master) }
        try #require(grantpt(master) == 0 && unlockpt(master) == 0)
        let path = String(cString: ptsname(master))

        let first = SerialConnection(path: path)
        try first.open(baud: 9_600, onData: { _ in }, onClose: {})
        defer { first.close() }
        // A second session must never interleave on the same line.
        #expect(throws: SerialConnection.Failure.self) {
            try SerialConnection(path: path).open(baud: 9_600, onData: { _ in }, onClose: {})
        }
    }

    @Test func portReopensAfterClose() throws {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        try #require(master >= 0)
        defer { close(master) }
        try #require(grantpt(master) == 0 && unlockpt(master) == 0)
        let path = String(cString: ptsname(master))

        let closed = DispatchSemaphore(value: 0)
        let first = SerialConnection(path: path)
        try first.open(baud: 9_600, onData: { _ in }, onClose: { closed.signal() })
        first.close()
        #expect(closed.wait(timeout: .now() + 3) == .success)
        // The claim is released with the session — the port is free again.
        let second = SerialConnection(path: path)
        try second.open(baud: 9_600, onData: { _ in }, onClose: {})
        second.close()
    }

    @Test func hexInputParsing() {
        #expect(Format.parseHexBytes("0d 0a ff") == Data([0x0D, 0x0A, 0xFF]))
        #expect(Format.parseHexBytes("0x0D,0x0A") == Data([0x0D, 0x0A]))
        #expect(Format.parseHexBytes("deadbeef") == Data([0xDE, 0xAD, 0xBE, 0xEF]))
        #expect(Format.parseHexBytes("abc") == nil)   // odd digit count
        #expect(Format.parseHexBytes("zz") == nil)
        #expect(Format.parseHexBytes("") == nil)
    }
}

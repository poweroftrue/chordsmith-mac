import Foundation
import Darwin

public enum SerialError: LocalizedError {
    case failedToOpen(path: String)
    case failedToConfigure
    case notOpen
    case writeFailed
    case readFailed
    case timeout

    public var errorDescription: String? {
        switch self {
        case .failedToOpen(let path):
            return "Failed to open serial port at \(path)."
        case .failedToConfigure:
            return "Failed to configure the serial port."
        case .notOpen:
            return "Serial port is not open."
        case .writeFailed:
            return "Failed to write to the serial port."
        case .readFailed:
            return "Failed to read from the serial port."
        case .timeout:
            return "Timed out waiting for device response."
        }
    }
}

public protocol DeviceCommandTransport: Sendable {
    func sendCommand(_ command: String, timeout: TimeInterval, flush: Bool) throws -> String
    func flush()
}

public final class SerialPort: DeviceCommandTransport, @unchecked Sendable {
    private let path: String
    private var fileDescriptor: Int32 = -1
    private var originalTermios = termios()
    private var readBuffer = [UInt8](repeating: 0, count: 4_096)
    private var bufferOffset = 0
    private var bufferLength = 0
    private let lock = NSLock()

    public init(path: String) {
        self.path = path
    }

    deinit {
        close()
    }

    public func open() throws {
        fileDescriptor = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fileDescriptor != -1 else {
            throw SerialError.failedToOpen(path: path)
        }

        guard tcgetattr(fileDescriptor, &originalTermios) == 0 else {
            close()
            throw SerialError.failedToConfigure
        }

        var settings = originalTermios
        cfmakeraw(&settings)
        cfsetispeed(&settings, speed_t(B115200))
        cfsetospeed(&settings, speed_t(B115200))
        settings.c_cflag &= ~UInt(CSIZE)
        settings.c_cflag |= UInt(CS8)
        settings.c_cflag &= ~UInt(PARENB)
        settings.c_cflag &= ~UInt(CSTOPB)
        settings.c_cflag |= UInt(CLOCAL | CREAD)
        settings.c_cflag &= ~UInt(CRTSCTS)
        settings.c_cc.16 = 0
        settings.c_cc.17 = 1

        guard tcsetattr(fileDescriptor, TCSANOW, &settings) == 0 else {
            close()
            throw SerialError.failedToConfigure
        }

        tcflush(fileDescriptor, TCIOFLUSH)
        let flags = fcntl(fileDescriptor, F_GETFL)
        _ = fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK)
        usleep(100_000)
    }

    public func close() {
        guard fileDescriptor != -1 else { return }
        tcsetattr(fileDescriptor, TCSANOW, &originalTermios)
        Darwin.close(fileDescriptor)
        fileDescriptor = -1
    }

    public func sendCommand(_ command: String, timeout: TimeInterval = 2.0, flush: Bool = true) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        guard fileDescriptor != -1 else {
            throw SerialError.notOpen
        }

        if flush {
            self.flush()
            usleep(2_000)
        }

        try write(command + "\r\n")
        return try readLine(timeout: timeout)
    }

    public func flush() {
        guard fileDescriptor != -1 else { return }
        bufferOffset = 0
        bufferLength = 0
        tcflush(fileDescriptor, TCIOFLUSH)
    }

    public func drainInput(for duration: TimeInterval = 0.2) {
        lock.lock()
        defer { lock.unlock() }

        guard fileDescriptor != -1 else { return }
        bufferOffset = 0
        bufferLength = 0

        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            let bytesRead = Darwin.read(fileDescriptor, &readBuffer, readBuffer.count)
            if bytesRead > 0 {
                continue
            }
            if bytesRead == 0 || errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                usleep(10_000)
                continue
            }
            break
        }
    }

    private func write(_ string: String) throws {
        let bytes = Array(string.utf8)
        var totalWritten = 0

        while totalWritten < bytes.count {
            let bytesWritten = bytes.withUnsafeBytes { bytesPointer in
                Darwin.write(fileDescriptor, bytesPointer.baseAddress!.advanced(by: totalWritten), bytes.count - totalWritten)
            }
            if bytesWritten > 0 {
                totalWritten += bytesWritten
            } else if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                usleep(1_000)
            } else {
                throw SerialError.writeFailed
            }
        }

        _ = tcdrain(fileDescriptor)
    }

    private func readLine(timeout: TimeInterval) throws -> String {
        let startTime = Date()
        var line = [UInt8]()

        while Date().timeIntervalSince(startTime) < timeout {
            if bufferOffset < bufferLength {
                let byte = readBuffer[bufferOffset]
                bufferOffset += 1
                if byte == 10 || byte == 13 {
                    if !line.isEmpty {
                        return String(decoding: line, as: UTF8.self)
                    }
                } else {
                    line.append(byte)
                }
                continue
            }

            bufferOffset = 0
            bufferLength = 0
            let bytesRead = Darwin.read(fileDescriptor, &readBuffer, readBuffer.count)
            if bytesRead > 0 {
                bufferLength = bytesRead
            } else if bytesRead == 0 || errno == EAGAIN || errno == EWOULDBLOCK {
                usleep(1_000)
            } else {
                throw SerialError.readFailed
            }
        }

        throw SerialError.timeout
    }

    public static func listCandidatePorts() -> [String] {
        let devURL = URL(fileURLWithPath: "/dev", isDirectory: true)
        let candidates = (try? FileManager.default.contentsOfDirectory(atPath: devURL.path)) ?? []
        return candidates
            .filter { $0.hasPrefix("cu.usbmodem") || $0.hasPrefix("cu.usbserial") }
            .map { "/dev/\($0)" }
            .sorted()
    }
}

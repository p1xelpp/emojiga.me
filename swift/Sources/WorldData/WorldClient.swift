import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

public final class WorldClient: @unchecked Sendable {
    public static let defaultPort: UInt16 = 27016

    public let playerID: String
    public let worldData: Data
    public let initialPlayers: [[String: Any]]
    public let floodRemaining: Double
    public let cometAvailable: Bool
    public let cometStruck: Bool
    public let openedChests: [Int]

    private let socketFD: Int32
    private let lock = NSLock()
    private var events: [[String: Any]] = []
    private var isConnected = true

    public var connected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isConnected
    }

    public init(host: String, port: UInt16 = WorldClient.defaultPort, timeout: TimeInterval = 5) throws {
        socketFD = try Self.connect(host: host, port: port, timeout: timeout)
        do {
            try Self.send(["type": "join"], on: socketFD)
            let response = try Self.readMessage(from: socketFD)
            guard response["type"] as? String == "welcome",
                  let playerID = response["id"] as? String,
                  let world = response["world"],
                  JSONSerialization.isValidJSONObject(world) else {
                let reason = response["message"] as? String ?? "Host sent an invalid welcome."
                throw WorldClientError.connectionRejected(reason)
            }

            self.playerID = playerID
            worldData = try JSONSerialization.data(withJSONObject: world)
            initialPlayers = response["players"] as? [[String: Any]] ?? []
            floodRemaining = response["flood_remaining"] as? Double ?? 0
            cometAvailable = response["comet_available"] as? Bool ?? true
            cometStruck = response["comet_struck"] as? Bool ?? false
            openedChests = (response["opened_chests"] as? [NSNumber])?.map(\.intValue) ?? (response["opened_chests"] as? [Int]) ?? []

            var timeoutValue = timeval(tv_sec: 0, tv_usec: 0)
            #if os(Linux)
            let timeoutOption = SO_RCVTIMEO
            #else
            let timeoutOption = SO_RCVTIMEO
            #endif
            _ = setsockopt(
                socketFD,
                SOL_SOCKET,
                timeoutOption,
                &timeoutValue,
                socklen_t(MemoryLayout<timeval>.size)
            )

            DispatchQueue.global(qos: .userInitiated).async { [self] in
                receiveLoop()
            }
        } catch {
            _ = GlibcOrDarwinClose(socketFD)
            throw error
        }
    }

    deinit {
        close()
    }

    public func poll() -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        let pending = events
        events.removeAll(keepingCapacity: true)
        return pending
    }

    public func sendPosition(_ position: [Double], rotationY: Double) {
        send([
            "type": "position",
            "position": position,
            "rotation_y": rotationY,
        ])
    }

    public func sendAttack(_ attack: String, origin: [Double], direction: [Double]) {
        send([
            "type": "attack",
            "attack": attack,
            "origin": origin,
            "direction": direction,
        ])
    }

    public func sendHit(targetID: String, attack: String, direction: [Double]) {
        send([
            "type": "player_hit",
            "target_id": targetID,
            "attack": attack,
            "direction": direction,
        ])
    }

    public func sendCometStrike() {
        send(["type": "comet_strike"])
    }

    public func sendDeath() {
        send(["type": "death"])
    }

    public func sendChestOpened(chestID: Int) {
        send([
            "type": "chest_opened",
            "chest_id": chestID,
        ])
    }

    public func close() {
        lock.lock()
        let shouldClose = isConnected
        isConnected = false
        lock.unlock()
        if shouldClose {
            _ = shutdown(socketFD, Int32(SHUT_RDWR))
            _ = GlibcOrDarwinClose(socketFD)
        }
    }

    private func send(_ message: [String: Any]) {
        lock.lock()
        let canSend = isConnected
        lock.unlock()
        guard canSend else { return }

        do {
            try Self.send(message, on: socketFD)
        } catch {
            enqueue([
                "type": "disconnected",
                "message": error.localizedDescription,
            ])
            close()
        }
    }

    private func receiveLoop() {
        while connected {
            do {
                enqueue(try Self.readMessage(from: socketFD))
            } catch {
                if connected {
                    enqueue([
                        "type": "disconnected",
                        "message": error.localizedDescription,
                    ])
                    close()
                }
                return
            }
        }
    }

    private func enqueue(_ message: [String: Any]) {
        lock.lock()
        events.append(message)
        lock.unlock()
    }

    private static func connect(host: String, port: UInt16, timeout: TimeInterval) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        var addresses: UnsafeMutablePointer<addrinfo>?
        let lookup = getaddrinfo(host, String(port), &hints, &addresses)
        guard lookup == 0, let firstAddress = addresses else {
            throw WorldClientError.connectionFailed(String(cString: gai_strerror(lookup)))
        }
        defer { freeaddrinfo(firstAddress) }

        var address = firstAddress
        var lastError: Int32 = ECONNREFUSED
        var lastFailure: String?
        while true {
            let descriptor = createSocket(address.pointee.ai_family, address.pointee.ai_socktype, address.pointee.ai_protocol)
            if descriptor >= 0 {
                do {
                    try connectSocket(
                        descriptor,
                        address: address.pointee.ai_addr,
                        length: address.pointee.ai_addrlen,
                        timeout: timeout
                    )
                    var timeoutValue = timeval()
                    timeoutValue.tv_sec = Int(timeout)
                    timeoutValue.tv_usec = 0
                    _ = setsockopt(
                        descriptor,
                        SOL_SOCKET,
                        SO_RCVTIMEO,
                        &timeoutValue,
                        socklen_t(MemoryLayout<timeval>.size)
                    )
                    _ = setsockopt(
                        descriptor,
                        SOL_SOCKET,
                        SO_SNDTIMEO,
                        &timeoutValue,
                        socklen_t(MemoryLayout<timeval>.size)
                    )
                    #if !os(Linux)
                    var noSignal: Int32 = 1
                    _ = setsockopt(
                        descriptor,
                        SOL_SOCKET,
                        SO_NOSIGPIPE,
                        &noSignal,
                        socklen_t(MemoryLayout<Int32>.size)
                    )
                    #endif
                    return descriptor
                } catch let error as WorldClientError {
                    if case .connectionFailed(let reason) = error {
                        lastFailure = reason
                    }
                    lastError = errno
                    _ = GlibcOrDarwinClose(descriptor)
                } catch {
                    lastFailure = error.localizedDescription
                    lastError = errno
                    _ = GlibcOrDarwinClose(descriptor)
                }
            } else {
                lastError = errno
            }
            guard let next = address.pointee.ai_next else { break }
            address = next
        }
        throw WorldClientError.connectionFailed(lastFailure ?? String(cString: strerror(lastError)))
    }

    private static func send(_ message: [String: Any], on socket: Int32) throws {
        var data = try JSONSerialization.data(withJSONObject: message, options: [.fragmentsAllowed])
        data.append(0x0A)
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var sent = 0
            while sent < bytes.count {
                #if os(Linux)
                let flags = Int32(MSG_NOSIGNAL)
                #else
                let flags = 0
                #endif
                let count = DarwinOrGlibcSend(
                    socket,
                    baseAddress.advanced(by: sent),
                    bytes.count - sent,
                    flags
                )
                guard count > 0 else {
                    throw WorldClientError.connectionFailed(String(cString: strerror(errno)))
                }
                sent += count
            }
        }
    }

    private static func readMessage(from socket: Int32) throws -> [String: Any] {
        var line = Data()
        while line.count < 1_048_576 {
            var byte: UInt8 = 0
            let count = withUnsafeMutablePointer(to: &byte) {
                DarwinOrGlibcRecv(socket, $0, 1, 0)
            }
            guard count > 0 else {
                if count == 0 {
                    throw WorldClientError.connectionClosed
                }
                throw WorldClientError.connectionFailed(String(cString: strerror(errno)))
            }
            if byte == 0x0A { break }
            line.append(byte)
        }
        guard line.count < 1_048_576,
              let message = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw WorldClientError.invalidMessage
        }
        return message
    }
}

public enum WorldClientError: LocalizedError {
    case connectionFailed(String)
    case connectionClosed
    case connectionRejected(String)
    case invalidMessage

    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let reason):
            "Could not connect to world host: \(reason)"
        case .connectionClosed:
            "World host closed the connection."
        case .connectionRejected(let reason):
            "World host rejected the connection: \(reason)"
        case .invalidMessage:
            "World host sent an invalid message."
        }
    }
}

private func DarwinOrGlibcConnect(
    _ socket: Int32,
    _ address: UnsafePointer<sockaddr>?,
    _ length: socklen_t
) -> Int32 {
    #if os(Linux)
    Glibc.connect(socket, address, length)
    #else
    Darwin.connect(socket, address, length)
    #endif
}

private func DarwinOrGlibcSend(
    _ socket: Int32,
    _ buffer: UnsafeRawPointer?,
    _ length: Int,
    _ flags: Int32
) -> Int {
    #if os(Linux)
    Glibc.send(socket, buffer, length, flags)
    #else
    Darwin.send(socket, buffer, length, flags)
    #endif
}

private func DarwinOrGlibcRecv(
    _ socket: Int32,
    _ buffer: UnsafeMutableRawPointer?,
    _ length: Int,
    _ flags: Int32
) -> Int {
    #if os(Linux)
    Glibc.recv(socket, buffer, length, flags)
    #else
    Darwin.recv(socket, buffer, length, flags)
    #endif
}

private func GlibcOrDarwinClose(_ socket: Int32) -> Int32 {
    #if os(Linux)
    Glibc.close(socket)
    #else
    Darwin.close(socket)
    #endif
}

private func createSocket(_ domain: Int32, _ type: Int32, _ protocol: Int32) -> Int32 {
    #if os(Linux)
    Glibc.socket(domain, type, `protocol`)
    #else
    Darwin.socket(domain, type, `protocol`)
    #endif
}

private func connectSocket(
    _ descriptor: Int32,
    address: UnsafePointer<sockaddr>?,
    length: socklen_t,
    timeout: TimeInterval
) throws {
    let originalFlags = fcntl(descriptor, F_GETFL)
    guard originalFlags >= 0, fcntl(descriptor, F_SETFL, originalFlags | O_NONBLOCK) == 0 else {
        throw WorldClientError.connectionFailed(String(cString: strerror(errno)))
    }

    let result = DarwinOrGlibcConnect(descriptor, address, length)
    if result < 0 && errno != EINPROGRESS {
        throw WorldClientError.connectionFailed(String(cString: strerror(errno)))
    }

    if result < 0 {
        var descriptorState = pollfd()
        descriptorState.fd = descriptor
        descriptorState.events = Int16(POLLOUT)
        let milliseconds = Int32(min(Double(Int32.max), max(1, timeout * 1_000)))
        let pollResult = poll(&descriptorState, 1, milliseconds)
        guard pollResult > 0 else {
            let reason = pollResult == 0 ? ETIMEDOUT : errno
            throw WorldClientError.connectionFailed(String(cString: strerror(reason)))
        }

        var socketError: Int32 = 0
        var errorLength = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(
            descriptor,
            SOL_SOCKET,
            SO_ERROR,
            &socketError,
            &errorLength
        ) == 0, socketError == 0 else {
            let reason = socketError == 0 ? errno : socketError
            throw WorldClientError.connectionFailed(String(cString: strerror(reason)))
        }
    }

    guard fcntl(descriptor, F_SETFL, originalFlags) == 0 else {
        throw WorldClientError.connectionFailed(String(cString: strerror(errno)))
    }
}

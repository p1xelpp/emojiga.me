import Foundation
import Testing
@testable import WorldData
#if os(Linux)
import Glibc
#else
import Darwin
#endif

@Test func worldClientReceivesMapAndSendsPositionUpdates() throws {
    let host = try LocalWorldHost()
    defer { host.stop() }

    let client = try WorldClient(host: "127.0.0.1", port: host.port)
    defer { client.close() }

    #expect(client.playerID == "test-player")
    #expect(client.connected)
    var world = try WorldEngine()
    try world.loadMap(from: client.worldData)
    #expect(world.blocks.count == 1)
    #expect(world.block(at: BlockPosition(x: 0.5, y: 0.5, z: 0.5))?.texture == "white_cube")

    client.sendPosition([1, 2, 3], rotationY: 45)
    let deadline = Date().addingTimeInterval(2)
    var receivedFlood = false
    while Date() < deadline && !receivedFlood {
        receivedFlood = client.poll().contains { $0["type"] as? String == "flood_start" }
        if !receivedFlood {
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    #expect(receivedFlood)
    #expect(host.receivedPosition)
}

private final class LocalWorldHost: @unchecked Sendable {
    let port: UInt16
    private let listener: Int32
    private let lock = NSLock()
    private var _receivedPosition = false

    var receivedPosition: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _receivedPosition
    }

    init() throws {
        let serverSocket = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard serverSocket >= 0 else {
            throw LocalHostError.socket(String(cString: strerror(errno)))
        }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: in_addr_t(0x7f000001).bigEndian)
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(serverSocket, 1) == 0 else {
            let reason = String(cString: strerror(errno))
            _ = closeSocket(serverSocket)
            throw LocalHostError.socket(reason)
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(serverSocket, $0, &length)
            }
        }
        guard nameResult == 0 else {
            let reason = String(cString: strerror(errno))
            _ = closeSocket(serverSocket)
            throw LocalHostError.socket(reason)
        }
        listener = serverSocket
        port = UInt16(bigEndian: boundAddress.sin_port)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            serve()
        }
    }

    func stop() {
        _ = shutdown(listener, Int32(SHUT_RDWR))
        _ = closeSocket(listener)
    }

    private func serve() {
        let connection = accept(listener, nil, nil)
        guard connection >= 0 else { return }
        defer {
            _ = shutdown(connection, Int32(SHUT_RDWR))
            _ = closeSocket(connection)
        }
        guard let join = readLine(from: connection),
              (try? JSONSerialization.jsonObject(with: join)) != nil else {
            return
        }
        let welcome = """
        {"type":"welcome","id":"test-player","world":{"version":1,"block_size":1,"blocks":[{"position":[0.5,0.5,0.5]}]},"players":[],"flood_remaining":0,"comet_available":true,"comet_struck":false}
        
        """
        guard send(Data(welcome.utf8), to: connection) else { return }
        guard let positionData = readLine(from: connection),
              let position = (try? JSONSerialization.jsonObject(with: positionData)) as? [String: Any],
              position["type"] as? String == "position" else {
            return
        }
        lock.lock()
        _receivedPosition = true
        lock.unlock()
        _ = send(Data(#"{"type":"flood_start","remaining":3}"#.utf8) + Data([0x0A]), to: connection)
    }

    private func readLine(from descriptor: Int32) -> Data? {
        var data = Data()
        while data.count < 64_000 {
            var byte: UInt8 = 0
            let count = withUnsafeMutablePointer(to: &byte) {
                receive(descriptor, $0, 1)
            }
            guard count > 0 else { return nil }
            if byte == 0x0A { return data }
            data.append(byte)
        }
        return nil
    }

    private func send(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return false }
            var sent = 0
            while sent < bytes.count {
                let count = transmit(descriptor, base.advanced(by: sent), bytes.count - sent)
                guard count > 0 else { return false }
                sent += count
            }
            return true
        }
    }
}

private enum LocalHostError: Error {
    case socket(String)
}

private func receive(_ descriptor: Int32, _ buffer: UnsafeMutablePointer<UInt8>, _ size: Int) -> Int {
    #if os(Linux)
    Glibc.recv(descriptor, buffer, size, 0)
    #else
    Darwin.recv(descriptor, buffer, size, 0)
    #endif
}

private func transmit(_ descriptor: Int32, _ buffer: UnsafeRawPointer, _ size: Int) -> Int {
    #if os(Linux)
    Glibc.send(descriptor, buffer, size, Int32(MSG_NOSIGNAL))
    #else
    Darwin.send(descriptor, buffer, size, 0)
    #endif
}

private func closeSocket(_ descriptor: Int32) -> Int32 {
    #if os(Linux)
    Glibc.close(descriptor)
    #else
    Darwin.close(descriptor)
    #endif
}

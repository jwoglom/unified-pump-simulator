import Foundation
#if canImport(Glibc)
    import Glibc
#else
    import Darwin
#endif

// faketandem's virtual GATT link, from the central's side (docs/virtual-gatt-protocol.md in the
// faketandem repository): one TCP connection per BLE connection, newline-delimited JSON, binary as
// lowercase hex. Pump messages are opaque bytes here; the link carries GATT semantics only.
// Foundation and POSIX sockets, so this file also compiles and is tested on Linux.

struct VirtualGattEndpoint: Equatable {
    static let `default` = VirtualGattEndpoint(host: "127.0.0.1", port: 8081)

    let host: String
    let port: UInt16

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    /// `host:port`; a bare port means 127.0.0.1.
    init?(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = trimmed.lastIndex(of: ":") else {
            guard let port = UInt16(trimmed) else {
                return nil
            }
            self.init(host: "127.0.0.1", port: port)
            return
        }
        let host = String(trimmed[..<colon])
        guard !host.isEmpty, let port = UInt16(trimmed[trimmed.index(after: colon)...]) else {
            return nil
        }
        self.init(host: host, port: port)
    }

    var description: String {
        "\(host):\(port)"
    }
}

enum VirtualGattError: Error, CustomStringConvertible {
    case connectFailed(String)
    case protocolError(String)
    case timedOut(String)
    /// The pump ended the link, with the reason it gave (`not_discoverable`, `radio_off`, `busy`, ...).
    case refused(reason: String)
    /// The socket closed with no `disconnect` message.
    case closed
    case rejected(String)

    var description: String {
        switch self {
        case let .connectFailed(reason): return "connect failed: \(reason)"
        case let .protocolError(reason): return "protocol error: \(reason)"
        case let .timedOut(what): return "timed out waiting for \(what)"
        case let .refused(reason): return "pump ended the link: \(reason)"
        case .closed: return "link closed"
        case let .rejected(reason): return "pump rejected the request: \(reason)"
        }
    }
}

struct VirtualGattCharacteristic: Equatable {
    static let read = "read"
    static let write = "write"
    static let writeWithoutResponse = "write_without_response"
    static let notify = "notify"
    static let indicate = "indicate"

    /// Normalized: lowercase, full 128-bit.
    let uuid: String
    let properties: [String]

    var isReadable: Bool {
        properties.contains(Self.read)
    }
}

struct VirtualGattService: Equatable {
    let uuid: String
    let characteristics: [VirtualGattCharacteristic]
}

/// The `hello` frame the peripheral sends on every connection.
struct VirtualGattHello: Equatable {
    static let notDiscoverablePairingState = "NotDiscoverable"

    let protocolVersion: Int
    let peripheralId: String
    let name: String
    let manufacturerData: Data?
    let pairingState: String
    let services: [VirtualGattService]
    /// The ATT MTU the pump fragments its notifications to.
    let attMTU: Int

    init?(_ message: [String: Any]) {
        guard message["type"] as? String == "hello" else {
            return nil
        }
        protocolVersion = message["protocol_version"] as? Int ?? 0
        peripheralId = message["peripheral_id"] as? String ?? ""
        name = message["name"] as? String ?? ""
        manufacturerData = (message["manufacturer_data"] as? String).flatMap { Data(hexString: $0) }
        pairingState = message["pairing_state"] as? String ?? ""
        attMTU = message["att_mtu"] as? Int ?? 23
        services = (message["services"] as? [[String: Any]] ?? []).compactMap { service in
            guard let uuid = service["uuid"] as? String else {
                return nil
            }
            let characteristics = (service["characteristics"] as? [[String: Any]] ?? []).compactMap { characteristic in
                (characteristic["uuid"] as? String).map {
                    VirtualGattCharacteristic(
                        uuid: VirtualGattLink.normalize(uuid: $0),
                        properties: characteristic["properties"] as? [String] ?? []
                    )
                }
            }
            return VirtualGattService(uuid: VirtualGattLink.normalize(uuid: uuid), characteristics: characteristics)
        }
    }

    var isDiscoverable: Bool {
        pairingState != Self.notDiscoverablePairingState
    }
}

enum VirtualGattEvent {
    /// One ATT notification, exactly as the pump would send it over the air.
    case notify(characteristic: String, value: Data)
    /// The pump ended the link (`reason` as it gave it), or the socket closed without a word (nil).
    case disconnected(reason: String?)
}

/// One connection to faketandem. `hello` is read before `init` returns; after that a reader thread
/// delivers notifications and the link's end to `onEvent` on `eventQueue`. The blocking calls
/// (`attach`, `read`) wait for their reply and may be made from any thread but `eventQueue`'s
/// callbacks' own link events are independent of them. `close` from any thread.
final class VirtualGattLink {
    private static let bluetoothBaseSuffix = "-0000-1000-8000-00805f9b34fb"

    /// Lowercase, 16- and 32-bit UUIDs expanded to the Bluetooth base, as the link spells every UUID.
    static func normalize(uuid: String) -> String {
        var value = uuid.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("0x") {
            value.removeFirst(2)
        }
        switch value.count {
        case 4:
            return "0000\(value)\(bluetoothBaseSuffix)"
        case 8:
            return "\(value)\(bluetoothBaseSuffix)"
        default:
            return value
        }
    }

    let endpoint: VirtualGattEndpoint
    let hello: VirtualGattHello

    private let socket: SocketLink
    private let eventQueue: DispatchQueue
    private let onEvent: (VirtualGattEvent) -> Void
    private let logger = PumpManagerLogger(subsystem: "com.bastiaanv.tandemkit", category: "VirtualGattLink")

    private let lock = NSCondition()
    private var nextId = 1
    private var pending: [Int: PendingReply] = [:]
    /// What each fire-and-forget request was, so its ack can be logged if it carries an error.
    private var inFlight: [Int: String] = [:]
    private var endedReason: String?
    private var ended = false
    private var closedByUs = false

    private final class PendingReply {
        var reply: [String: Any]?
    }

    init(
        endpoint: VirtualGattEndpoint,
        helloTimeout: TimeInterval = 3,
        eventQueue: DispatchQueue,
        onEvent: @escaping (VirtualGattEvent) -> Void
    ) throws {
        self.endpoint = endpoint
        self.eventQueue = eventQueue
        self.onEvent = onEvent
        socket = try SocketLink(connectTo: endpoint)

        do {
            guard let message = try socket.readMessage(timeout: helloTimeout) else {
                throw VirtualGattError.closed
            }
            guard let hello = VirtualGattHello(message) else {
                throw VirtualGattError.protocolError("expected hello, got \(message["type"] ?? "?")")
            }
            self.hello = hello
        } catch {
            socket.close()
            throw error
        }

        let thread = Thread { [self] in readLoop() }
        thread.name = "VirtualGattLink.reader"
        thread.start()
    }

    deinit {
        close()
    }

    // MARK: - Requests

    /// Declares this a real BLE connection; the pump fires its connection handler.
    func attach(timeout: TimeInterval = 3) throws {
        _ = try request(["type": "attach"], timeout: timeout, expecting: "attach_ack")
    }

    func read(characteristic: String, timeout: TimeInterval = 3) throws -> Data {
        let reply = try request(
            ["type": "read", "characteristic": characteristic],
            timeout: timeout,
            expecting: "read_result"
        )
        // An empty value is left out of the reply altogether.
        guard let value = Data(hexString: reply["value"] as? String ?? "") else {
            throw VirtualGattError.protocolError("read_result value is not hex")
        }
        return value
    }

    /// Fire and forget: the ack is logged only if it carries an error.
    func subscribe(characteristic: String, enabled: Bool) {
        send(["type": "subscribe", "characteristic": characteristic, "enabled": enabled], as: "subscribe \(characteristic)")
    }

    /// One ATT write of exactly these bytes. Fire and forget, as the ack precedes any response.
    func write(characteristic: String, value: Data, withResponse: Bool) {
        send(
            ["type": "write", "characteristic": characteristic, "value": value.hexString(), "with_response": withResponse],
            as: "write \(characteristic)"
        )
    }

    /// Ends the connection from the central's side, as a BLE disconnect would.
    func disconnect() {
        lock.lock()
        let alreadyEnded = ended
        lock.unlock()
        if !alreadyEnded {
            send(["type": "disconnect"], as: "disconnect")
        }
        close()
    }

    /// Releases the socket. The link reports nothing after this.
    func close() {
        lock.lock()
        closedByUs = true
        lock.unlock()
        socket.shutdown()
    }

    // MARK: - Transport

    private func send(_ message: [String: Any], as description: String) {
        var message = message
        lock.lock()
        let id = nextId
        nextId += 1
        inFlight[id] = description
        lock.unlock()
        message["id"] = id
        do {
            try socket.send(message)
        } catch {
            logger.error("Failed to send \(description): \(error)")
        }
    }

    private func request(_ message: [String: Any], timeout: TimeInterval, expecting type: String) throws -> [String: Any] {
        var message = message
        let slot = PendingReply()
        lock.lock()
        if ended {
            let reason = endedReason
            lock.unlock()
            throw reason.map { VirtualGattError.refused(reason: $0) } ?? VirtualGattError.closed
        }
        let id = nextId
        nextId += 1
        pending[id] = slot
        lock.unlock()
        message["id"] = id

        do {
            try socket.send(message)
        } catch {
            lock.lock()
            pending[id] = nil
            lock.unlock()
            throw error
        }

        lock.lock()
        defer { lock.unlock() }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while slot.reply == nil, !ended {
            if !lock.wait(until: deadline) {
                break
            }
        }
        pending[id] = nil
        guard let reply = slot.reply else {
            if ended {
                throw endedReason.map { VirtualGattError.refused(reason: $0) } ?? VirtualGattError.closed
            }
            throw VirtualGattError.timedOut(type)
        }
        if let error = reply["error"] as? String {
            throw VirtualGattError.rejected(error)
        }
        guard reply["type"] as? String == type else {
            throw VirtualGattError.protocolError("expected \(type), got \(reply["type"] ?? "?")")
        }
        return reply
    }

    private func readLoop() {
        defer { socket.close() }
        while true {
            let message: [String: Any]?
            do {
                message = try socket.readMessage(timeout: nil)
            } catch {
                logger.error("Link read failed: \(error)")
                message = nil
            }
            guard let message else {
                end(reason: nil)
                return
            }
            if let id = message["id"] as? Int {
                deliverReply(id: id, message)
                continue
            }
            switch message["type"] as? String {
            case "notify":
                guard let characteristic = message["characteristic"] as? String,
                      let value = (message["value"] as? String).flatMap({ Data(hexString: $0) })
                else {
                    logger.warning("Dropping malformed notify: \(message)")
                    continue
                }
                emit(.notify(characteristic: Self.normalize(uuid: characteristic), value: value))
            case "disconnect":
                end(reason: message["reason"] as? String ?? "unknown")
                return
            case "error":
                logger.warning("Link error: \(message["error"] as? String ?? "?")")
            default:
                logger.warning("Unexpected link message: \(message)")
            }
        }
    }

    private func deliverReply(id: Int, _ message: [String: Any]) {
        lock.lock()
        if let slot = pending[id] {
            slot.reply = message
            lock.broadcast()
            lock.unlock()
            return
        }
        let description = inFlight.removeValue(forKey: id)
        lock.unlock()
        if let error = message["error"] as? String {
            logger.error("\(description ?? "request \(id)") failed: \(error)")
        }
    }

    /// The link is over: wakes every waiter and reports it once, unless we closed it ourselves.
    private func end(reason: String?) {
        lock.lock()
        let wasEnded = ended
        ended = true
        endedReason = reason
        let report = !closedByUs && !wasEnded
        lock.broadcast()
        lock.unlock()
        if report {
            emit(.disconnected(reason: reason))
        }
    }

    private func emit(_ event: VirtualGattEvent) {
        let onEvent = onEvent
        eventQueue.async {
            onEvent(event)
        }
    }
}

/// A connected TCP socket speaking newline-delimited JSON. `readMessage` is for one reader thread;
/// `send` may be called from any thread; `shutdown` from any thread unblocks the reader, which then
/// calls `close`. After TandemKit's VirtualPumpLink, which talks to the same server.
final class SocketLink {
    private let fd: Int32
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var isShutDown = false
    private var isClosed = false
    private var buffer: [UInt8] = []

    init(connectTo endpoint: VirtualGattEndpoint) throws {
        var hints = addrinfo()
        #if canImport(Glibc)
            hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
            hints.ai_socktype = SOCK_STREAM
        #endif
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(endpoint.host, String(endpoint.port), &hints, &result)
        guard status == 0, let first = result else {
            throw VirtualGattError.connectFailed("getaddrinfo(\(endpoint.host)): \(String(cString: gai_strerror(status)))")
        }
        defer { freeaddrinfo(result) }

        var lastError = "no addresses"
        var connected: Int32 = -1
        var candidate: UnsafeMutablePointer<addrinfo>? = first
        while let info = candidate, connected < 0 {
            candidate = info.pointee.ai_next
            let sock = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            guard sock >= 0 else {
                lastError = String(cString: strerror(errno))
                continue
            }
            if Glue.connect(sock, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 {
                connected = sock
            } else {
                lastError = String(cString: strerror(errno))
                Glue.close(sock)
            }
        }
        guard connected >= 0 else {
            throw VirtualGattError.connectFailed("connect(\(endpoint.host):\(endpoint.port)): \(lastError)")
        }
        var one: Int32 = 1
        setsockopt(connected, Int32(IPPROTO_TCP), TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        Glue.suppressSigpipe(connected)
        fd = connected
    }

    func send(_ message: [String: Any]) throws {
        var line = try JSONSerialization.data(withJSONObject: message)
        line.append(UInt8(0x0A))
        writeLock.lock()
        defer { writeLock.unlock() }
        try line.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < raw.count {
                let written = Glue.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw VirtualGattError.connectFailed("write: \(String(cString: strerror(errno)))")
                }
                offset += written
            }
        }
    }

    /// Next JSON object, or nil at EOF. `timeout` nil blocks until one arrives.
    func readMessage(timeout: TimeInterval?) throws -> [String: Any]? {
        guard let line = try readLine(timeout: timeout) else {
            return nil
        }
        guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw VirtualGattError.protocolError("not a JSON object: \(String(decoding: line, as: UTF8.self))")
        }
        return object
    }

    private func readLine(timeout: TimeInterval?) throws -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if line.isEmpty {
                    continue
                }
                return line
            }

            if let timeout {
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, Int32(timeout * 1000))
                if ready == 0 {
                    throw VirtualGattError.timedOut("hello")
                }
                if ready < 0, errno != EINTR {
                    throw VirtualGattError.connectFailed("poll: \(String(cString: strerror(errno)))")
                }
            }

            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = Glue.read(fd, &chunk, chunk.count)
            if count == 0 {
                return nil
            }
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                return nil
            }
            buffer.append(contentsOf: chunk[0 ..< count])
        }
    }

    /// Breaks a blocked `readMessage` on the reader thread with EOF. The descriptor itself is
    /// released by `close`, which only the reader calls, so a recycled descriptor is never read.
    func shutdown() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isShutDown, !isClosed else {
            return
        }
        isShutDown = true
        Glue.shutdown(fd, Int32(SHUT_RDWR))
    }

    func close() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isClosed else {
            return
        }
        isClosed = true
        Glue.close(fd)
    }

    deinit {
        close()
    }
}

/// The libc calls, named so they are not shadowed by this file's own methods.
private enum Glue {
    static func connect(_ fd: Int32, _ addr: UnsafePointer<sockaddr>?, _ len: socklen_t) -> Int32 {
        #if canImport(Glibc)
            Glibc.connect(fd, addr, len)
        #else
            Darwin.connect(fd, addr, len)
        #endif
    }

    /// Writing to a closed peer must fail with EPIPE, not SIGPIPE-kill the app.
    static func suppressSigpipe(_ fd: Int32) {
        #if !canImport(Glibc)
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    static func write(_ fd: Int32, _ buf: UnsafeRawPointer, _ count: Int) -> Int {
        #if canImport(Glibc)
            Glibc.send(fd, buf, count, Int32(MSG_NOSIGNAL))
        #else
            Darwin.write(fd, buf, count)
        #endif
    }

    static func read(_ fd: Int32, _ buf: UnsafeMutableRawPointer, _ count: Int) -> Int {
        #if canImport(Glibc)
            Glibc.read(fd, buf, count)
        #else
            Darwin.read(fd, buf, count)
        #endif
    }

    static func shutdown(_ fd: Int32, _ how: Int32) {
        #if canImport(Glibc)
            _ = Glibc.shutdown(fd, how)
        #else
            _ = Darwin.shutdown(fd, how)
        #endif
    }

    static func close(_ fd: Int32) {
        #if canImport(Glibc)
            _ = Glibc.close(fd)
        #else
            _ = Darwin.close(fd)
        #endif
    }
}

extension Data {
    /// Lowercase hex without separators, or nil for anything else. Unlike `Data(hex:)` in Utils, which
    /// traps on bad input, the link never trusts what it reads.
    init?(hexString: String) {
        let characters = Array(hexString.utf8)
        guard characters.count.isMultiple(of: 2) else {
            return nil
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(characters.count / 2)
        var index = 0
        while index < characters.count {
            guard let high = Self.nibble(characters[index]), let low = Self.nibble(characters[index + 1]) else {
                return nil
            }
            bytes.append(high << 4 | low)
            index += 2
        }
        self.init(bytes)
    }

    private static func nibble(_ character: UInt8) -> UInt8? {
        switch character {
        case UInt8(ascii: "0") ... UInt8(ascii: "9"): return character - UInt8(ascii: "0")
        case UInt8(ascii: "a") ... UInt8(ascii: "f"): return character - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A") ... UInt8(ascii: "F"): return character - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
}

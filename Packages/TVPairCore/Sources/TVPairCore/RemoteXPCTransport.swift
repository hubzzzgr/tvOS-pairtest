import Foundation

indirect enum XPCValue: Equatable {
    case null, bool(Bool), signed(Int64), unsigned(UInt64), string(String), data(Data), uuid(UUID), array([XPCValue]), dictionary([String: XPCValue])
    var dictionary: [String: XPCValue]? { if case let .dictionary(value) = self { return value }; return nil }
    var string: String? { if case let .string(value) = self { return value }; return nil }
    var unsigned: UInt64? { if case let .unsigned(value) = self { return value }; if case let .signed(value) = self, value >= 0 { return UInt64(value) }; return nil }
}

enum XPCCodec {
    static func le(_ value: UInt64, count: Int = 4) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
    static func number(_ data: Data, _ offset: Int, count: Int = 4) -> UInt64 { data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + count)).enumerated().reduce(0) { $0 | UInt64($1.element) << ($1.offset * 8) } }
    static func padded(_ data: Data) -> Data { data + Data(repeating: 0, count: (4 - data.count % 4) % 4) }
    static func object(_ value: XPCValue) throws -> Data {
        switch value {
        case .null: return le(0x1000)
        case let .bool(value): return le(0x2000) + le(value ? 1 : 0)
        case let .signed(value): return le(0x3000) + le(UInt64(bitPattern: value), count: 8)
        case let .unsigned(value): return le(0x4000) + le(value, count: 8)
        case let .string(value):
            let bytes = Data(value.utf8) + Data([0]); return le(0x9000) + le(UInt64(bytes.count)) + padded(bytes)
        case let .data(value): return le(0x8000) + le(UInt64(value.count)) + padded(value)
        case let .uuid(value): var bytes = value.uuid; return le(0xa000) + withUnsafeBytes(of: &bytes) { Data($0) }
        case let .array(values):
            var content = le(UInt64(values.count)); for value in values { content += try object(value) }
            return le(0xe000) + le(UInt64(content.count)) + content
        case let .dictionary(values):
            var content = le(UInt64(values.count))
            for key in values.keys.sorted() { content += padded(Data(key.utf8) + Data([0])); content += try object(values[key]!) }
            return le(0xf000) + le(UInt64(content.count)) + content
        }
    }
    static func wrapper(_ value: XPCValue?, flags: UInt32, id: UInt64 = 0) throws -> Data {
        let body: Data
        if let value { body = le(0x42133742) + le(5) + (try object(value)) } else { body = Data() }
        guard body.count <= 1_048_576 else { throw TVPairError.malformed("XPC message size") }
        return le(0x29b00b92) + le(UInt64(flags)) + le(UInt64(body.count), count: 8) + le(id, count: 8) + body
    }
    static func decodeBody(_ data: Data) throws -> XPCValue {
        var cursor = Cursor(data: data.zeroBased)
        guard try cursor.integer(4) == 0x42133742, try cursor.integer(4) == 5 else { throw TVPairError.malformed("XPC object header") }
        let value = try cursor.read(depth: 0)
        guard cursor.offset == data.count else { throw TVPairError.malformed("trailing XPC data") }; return value
    }
    private struct Cursor {
        let data: Data; var offset = 0
        mutating func take(_ count: Int) throws -> Data {
            guard count >= 0, count <= data.count - offset else { throw TVPairError.malformed("truncated XPC value") }
            defer { offset += count }; return data.subdata(in: offset..<(offset + count))
        }
        mutating func integer(_ count: Int) throws -> UInt64 { try take(count).enumerated().reduce(0) { $0 | UInt64($1.element) << ($1.offset * 8) } }
        mutating func read(depth: Int) throws -> XPCValue {
            guard depth < 32 else { throw TVPairError.malformed("XPC recursion limit") }
            let tag = try integer(4)
            switch tag {
            case 0x1000: return .null
            case 0x2000: return .bool(try integer(4) != 0)
            case 0x3000: return .signed(Int64(bitPattern: try integer(8)))
            case 0x4000: return .unsigned(try integer(8))
            case 0x5000, 0x7000: return .data(try take(8)) // Preserve numeric metadata we do not display.
            case 0x8000, 0x9000:
                let size = try integer(4); guard size <= 1_048_576 else { throw TVPairError.malformed("XPC scalar length") }
                let bytes = try take(Int(size)); _ = try take((4 - Int(size) % 4) % 4)
                if tag == 0x8000 { return .data(bytes) }
                guard bytes.last == 0, let value = String(data: bytes.dropLast(), encoding: .utf8) else { throw TVPairError.malformed("XPC string") }
                return .string(value)
            case 0xa000:
                let bytes = Array(try take(16))
                return .uuid(UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15])))
            case 0xe000, 0xf000:
                let length = try integer(4)
                guard length >= 4, length <= UInt64(data.count - offset) else { throw TVPairError.malformed("XPC collection length") }
                let end = offset + Int(length), count = try integer(4)
                guard count <= 4096 else { throw TVPairError.malformed("XPC collection count") }
                var array: [XPCValue] = [], dictionary: [String: XPCValue] = [:]
                for _ in 0..<Int(count) {
                    if tag == 0xf000 {
                        guard let zero = data[offset..<end].firstIndex(of: 0) else { throw TVPairError.malformed("XPC dictionary key") }
                        let size = zero - offset + 1, bytes = try take(size); _ = try take((4 - size % 4) % 4)
                        guard let key = String(data: bytes.dropLast(), encoding: .utf8), dictionary[key] == nil else { throw TVPairError.malformed("XPC duplicate key") }
                        dictionary[key] = try read(depth: depth + 1)
                    } else { array.append(try read(depth: depth + 1)) }
                    guard offset <= end else { throw TVPairError.malformed("XPC collection overrun") }
                }
                guard offset == end else { throw TVPairError.malformed("XPC collection boundary") }
                return tag == 0xf000 ? .dictionary(dictionary) : .array(array)
            default: throw TVPairError.unsupported("XPC object tag")
            }
        }
    }
}

actor RemoteXPCTransport {
    let stream: any ByteTransport
    var partial: [UInt32: Data] = [:]
    var nextID: UInt64 = 1
    init(stream: any ByteTransport) { self.stream = stream }
    static func frame(type: UInt8, flags: UInt8 = 0, channel: UInt32 = 0, body: Data = Data()) throws -> Data {
        guard body.count <= 16384 else { throw TVPairError.malformed("HTTP/2 outbound frame size") }
        return IPv6TCPPacket.be(UInt32(body.count), count: 3) + Data([type, flags]) + IPv6TCPPacket.be(channel) + body
    }
    func sendFrame(type: UInt8, flags: UInt8 = 0, channel: UInt32 = 0, body: Data = Data()) async throws {
        try await stream.send(Self.frame(type: type, flags: flags, channel: channel, body: body), timeout: 10)
    }
    func open() async throws {
        try await stream.connect(timeout: 10)
        try await stream.send(Data("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8), timeout: 10)
        try await sendFrame(type: 4, body: Data([0,3,0,0,0,100,0,4,0,16,0,0]))
        try await sendFrame(type: 8, body: IPv6TCPPacket.be(983041))
        try await sendFrame(type: 1, flags: 4, channel: 1)
        try await sendFrame(type: 0, channel: 1, body: XPCCodec.wrapper(.dictionary([:]), flags: 1))
        try await sendFrame(type: 1, flags: 4, channel: 3)
        try await sendFrame(type: 0, channel: 3, body: XPCCodec.wrapper(nil, flags: 0x400001))
        try await sendFrame(type: 0, channel: 1, body: XPCCodec.wrapper(nil, flags: 0x201))
    }
    func send(_ value: XPCValue, reply: Bool = false) async throws {
        let body = try XPCCodec.wrapper(value, flags: reply ? 0x10101 : 0x101, id: nextID); nextID += 1
        try await sendFrame(type: 0, channel: 1, body: body)
    }
    func receive(timeout: TimeInterval = 15) async throws -> XPCValue {
        let deadline = Date().addingTimeInterval(timeout)
        for _ in 0..<512 {
            for channel: UInt32 in [1, 3] {
                var buffer = partial[channel, default: Data()]
                while buffer.count >= 24 {
                    guard XPCCodec.number(buffer, 0) == 0x29b00b92 else { throw TVPairError.malformed("XPC wrapper magic") }
                    let size = XPCCodec.number(buffer, 8, count: 8)
                    guard size <= 1_048_576 else { throw TVPairError.malformed("XPC wrapper length") }
                    guard buffer.count >= 24 + Int(size) else { break }
                    let body = buffer.subdata(in: 24..<(24 + Int(size))); buffer = buffer.dropFirst(24 + Int(size)).zeroBased; partial[channel] = buffer
                    if size == 0 { continue }
                    let value = try XPCCodec.decodeBody(body)
                    if value.dictionary?.isEmpty == true { continue }
                    return value
                }
            }
            guard deadline.timeIntervalSinceNow > 0 else { throw TVPairError.timeout }
            let header = try await stream.readExactly(9, timeout: deadline.timeIntervalSinceNow)
            let size = Int(IPv6TCPPacket.number(header, 0, count: 3)), type = header[3], flags = header[4]
            let channel = IPv6TCPPacket.number(header, 5, count: 4) & 0x7fff_ffff
            guard size <= 16384 else { throw TVPairError.malformed("HTTP/2 inbound frame size") }
            let body = try await stream.readExactly(size, timeout: max(0.001, deadline.timeIntervalSinceNow))
            switch type {
            case 0:
                guard channel == 1 || channel == 3 else { throw TVPairError.unsupported("unexpected HTTP/2 stream") }
                var content = body
                if flags & 8 != 0 {
                    guard let padding = body.first, Int(padding) + 1 <= body.count else { throw TVPairError.malformed("HTTP/2 padding") }
                    content = body.subdata(in: 1..<(body.count - Int(padding)))
                }
                guard partial[channel, default: Data()].count + content.count <= 1_048_600 else { throw TVPairError.malformed("XPC accumulation limit") }
                partial[channel, default: Data()].append(content)
                if size > 0 {
                    try await sendFrame(type: 8, body: IPv6TCPPacket.be(UInt32(size)))
                    try await sendFrame(type: 8, channel: channel, body: IPv6TCPPacket.be(UInt32(size)))
                }
                if flags & 1 != 0 && content.isEmpty { throw TVPairError.closed }
            case 4:
                guard channel == 0, size % 6 == 0, flags & 1 == 0 || size == 0 else { throw TVPairError.malformed("HTTP/2 SETTINGS") }
                if flags & 1 == 0 { try await sendFrame(type: 4, flags: 1) }
            case 6:
                guard channel == 0 && size == 8 else { throw TVPairError.malformed("HTTP/2 PING") }
                if flags & 1 == 0 { try await sendFrame(type: 6, flags: 1, body: body) }
            case 3, 7: throw TVPairError.closed
            case 1, 8: break
            default: throw TVPairError.unsupported("HTTP/2 frame type")
            }
        }
        throw TVPairError.timeout
    }
}

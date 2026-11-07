import Foundation
import CoreFoundation

/// Foundation-only values accepted from Instruments archives. No arbitrary
/// Objective-C classes or peer-supplied error descriptions are instantiated.
indirect enum DTXValue: Equatable, Sendable {
    case null, bool(Bool), integer(Int64), real(Double), string(String), data(Data)
    case array([DTXValue]), dictionary([String: DTXValue]), error(Int)
    var dictionary: [String: DTXValue]? { if case let .dictionary(v) = self { return v }; return nil }
    var integer: Int64? { if case let .integer(v) = self { return v }; return nil }
    var string: String? { if case let .string(v) = self { return v }; return nil }
    private var foundation: Any {
        switch self {
        case .null: return NSNull()
        case let .bool(v): return NSNumber(value: v)
        case let .integer(v): return NSNumber(value: v)
        case let .real(v): return NSNumber(value: v)
        case let .string(v): return v as NSString
        case let .data(v): return v as NSData
        case let .array(v): return v.map(\.foundation) as NSArray
        case let .dictionary(v): return v.mapValues(\.foundation) as NSDictionary
        case let .error(code): return NSError(domain: "TVPair.Instruments", code: code)
        }
    }
    func archived() throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: foundation, requiringSecureCoding: false)
    }
    static func unarchive(_ bytes: Data) throws -> DTXValue {
        guard bytes.count <= 1_048_576 else { throw TVPairError.malformed("Instruments archive size") }
        do {
            let decoder = try NSKeyedUnarchiver(forReadingFrom: bytes)
            decoder.requiresSecureCoding = true; decoder.decodingFailurePolicy = .setErrorAndReturn
            defer { decoder.finishDecoding() }
            let classes: [AnyClass] = [NSString.self, NSNumber.self, NSArray.self, NSDictionary.self, NSData.self, NSDate.self, NSURL.self, NSUUID.self, NSNull.self, NSError.self]
            guard let object = decoder.decodeObject(of: classes, forKey: NSKeyedArchiveRootObjectKey), decoder.error == nil else { throw TVPairError.malformed("Instruments archive classes") }
            return try convert(object, depth: 0)
        } catch let error as TVPairError { throw error }
        catch { throw TVPairError.malformed("Instruments keyed archive") }
    }
    private static func convert(_ object: Any, depth: Int) throws -> DTXValue {
        guard depth < 32 else { throw TVPairError.malformed("Instruments archive depth") }
        if let error = object as? NSError { return .error(error.code) }
        if object is NSNull { return .null }
        if let value = object as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() { return .bool(value.boolValue) }
            let type = String(cString: value.objCType)
            return type == "d" || type == "f" ? .real(value.doubleValue) : .integer(value.int64Value)
        }
        if let value = object as? String { return .string(value) }
        if let value = object as? Data { return .data(value) }
        if let value = object as? Date { return .real(value.timeIntervalSince1970) }
        if let value = object as? URL { return .string(value.absoluteString) }
        if let value = object as? UUID { return .string(value.uuidString) }
        if let values = object as? [String: Any] {
            guard values.count <= 4096 else { throw TVPairError.malformed("Instruments dictionary limit") }
            return .dictionary(try values.mapValues { try convert($0, depth: depth + 1) })
        }
        if let values = object as? [Any] {
            guard values.count <= 4096 else { throw TVPairError.malformed("Instruments array limit") }
            return .array(try values.map { try convert($0, depth: depth + 1) })
        }
        throw TVPairError.unsupported("Instruments archive value type")
    }
}

enum DTXArgument: Sendable { case u32(UInt32), object(DTXValue) }
struct DTXMessage: Sendable {
    let identifier: UInt32, conversation: UInt32
    let wireChannel: Int32
    let expectsReply: Bool
    let type: UInt32
    let arguments: [DTXValue]
    let value: DTXValue?
    var channel: Int32 { conversation % 2 == 0 ? -wireChannel : wireChannel }
}

enum DTXCodec {
    static func le(_ v: UInt64, _ size: Int = 4) -> Data { XPCCodec.le(v, count: size) }
    static func number(_ b: Data, _ p: Int, _ size: Int = 4) -> UInt64 { XPCCodec.number(b, p, count: size) }
    static func encode(id: UInt32, channel: Int32, conversation: UInt32 = 0, expectsReply: Bool = true, type: UInt32 = 2, value: DTXValue?, arguments: [DTXArgument] = []) throws -> Data {
        var aux = Data()
        for arg in arguments {
            aux += le(10)
            switch arg {
            case let .u32(v): aux += le(3) + le(UInt64(v))
            case let .object(v):
                let data = try v.archived(); aux += le(2) + le(UInt64(data.count)) + data
            }
        }
        if !aux.isEmpty { aux = le(0x1f0) + le(0) + le(UInt64(aux.count), 8) + aux }
        let object = try value?.archived() ?? Data()
        let payload = le(UInt64(type)) + le(UInt64(aux.count)) + le(UInt64(aux.count + object.count), 8) + aux + object
        guard payload.count <= 1_048_576 else { throw TVPairError.malformed("Instruments frame limit") }
        var header = le(0x1f3d5b79) + le(32) + le(0, 2) + le(1, 2)
        header += le(UInt64(payload.count)) + le(UInt64(id)) + le(UInt64(conversation))
        header += le(UInt64(UInt32(bitPattern: channel))) + le(expectsReply ? 1 : 0)
        return header + payload
    }
    static func decodePayload(_ data: Data, id: UInt32, conversation: UInt32, channel: Int32, expectsReply: Bool) throws -> DTXMessage {
        let b = data.zeroBased
        guard b.count >= 16 else { throw TVPairError.malformed("Instruments payload header") }
        let flags = UInt32(number(b, 0)), auxSize = Int(number(b, 4)), total = number(b, 8, 8)
        guard flags <= 4 else { throw TVPairError.unsupported("compressed or unknown Instruments message type") }
        guard total == UInt64(b.count - 16), auxSize <= b.count - 16 else { throw TVPairError.malformed("Instruments payload lengths") }
        var args: [DTXValue] = []
        if auxSize > 0 {
            guard auxSize >= 16, number(b, 16) == 0x1f0, number(b, 24, 8) == UInt64(auxSize - 16) else { throw TVPairError.malformed("Instruments auxiliary header") }
            var p = 32
            let end = 16 + auxSize
            while p < end {
                guard args.count < 64, p + 4 <= end else { throw TVPairError.malformed("Instruments auxiliary count") }
                let type = number(b, p); p += 4
                if type == 10 { continue }
                if type == 3 {
                    guard p + 4 <= end else { throw TVPairError.malformed("Instruments integer argument") }
                    args.append(.integer(Int64(number(b, p)))); p += 4
                } else if type == 6 || type == 9 {
                    guard p + 8 <= end else { throw TVPairError.malformed("Instruments wide argument") }
                    let v = number(b, p, 8); p += 8
                    args.append(type == 6 ? .integer(Int64(bitPattern: v)) : .real(Double(bitPattern: v)))
                } else if type == 1 || type == 2 {
                    guard p + 4 <= end else { throw TVPairError.malformed("Instruments argument size") }
                    let size = Int(number(b, p)); p += 4
                    guard size <= end - p else { throw TVPairError.malformed("Instruments argument boundary") }
                    let bytes = b.subdata(in: p..<p + size); p += size
                    if type == 2 { args.append(try DTXValue.unarchive(bytes)) }
                    else {
                        guard let string = String(data: bytes, encoding: .utf8) else { throw TVPairError.malformed("Instruments string argument") }
                        args.append(.string(string))
                    }
                } else { throw TVPairError.unsupported("Instruments argument type") }
            }
        }
        let object = b.subdata(in: (16 + auxSize)..<b.count)
        return DTXMessage(identifier: id, conversation: conversation, wireChannel: channel, expectsReply: expectsReply, type: flags, arguments: args, value: object.isEmpty ? nil : try DTXValue.unarchive(object))
    }
    static func receive(from stream: any ByteTransport, deadline: Date) async throws -> DTXMessage {
        var body = Data(), first: Data?, expected = 0, fragments = 1
        while expected < fragments {
            try Task.checkCancellation()
            guard deadline.timeIntervalSinceNow > 0 else { throw TVPairError.timeout }
            let h = try await stream.readExactly(32, timeout: deadline.timeIntervalSinceNow).zeroBased
            guard number(h, 0) == 0x1f3d5b79, number(h, 4) == 32, number(h, 12) <= 1_048_576, number(h, 28) <= 1 else { throw TVPairError.malformed("Instruments message header") }
            guard number(h, 24) != 0x80000000, number(h, 20) < UInt32.max else { throw TVPairError.malformed("Instruments channel or conversation") }
            let index = Int(number(h, 8, 2)), count = Int(number(h, 10, 2))
            guard (1...64).contains(count), index == expected else { throw TVPairError.malformed("Instruments fragment order") }
            if let first {
                guard count == fragments, h.subdata(in: 16..<32) == first.subdata(in: 16..<32) else { throw TVPairError.malformed("Instruments fragment identity") }
            } else { first = h; fragments = count }
            let size = Int(number(h, 12))
            // Fragment zero is an aggregate-size announcement, with no body.
            if count == 1 || index != 0 {
                guard size <= 1_048_576 - body.count else { throw TVPairError.malformed("Instruments reassembly limit") }
                body += try await stream.readExactly(size, timeout: max(0.001, deadline.timeIntervalSinceNow))
            }
            expected += 1
        }
        guard let h = first else { throw TVPairError.malformed("Instruments empty message") }
        return try decodePayload(body, id: UInt32(number(h, 16)), conversation: UInt32(number(h, 20)), channel: Int32(bitPattern: UInt32(number(h, 24))), expectsReply: number(h, 28) == 1)
    }
}

actor InstrumentsTransport {
    private let stream: any ByteTransport
    private var nextID: UInt32 = 1, nextChannel: Int32 = 1
    private var capabilities: [String: DTXValue]?
    private var calling = false
    init(stream: any ByteTransport) { self.stream = stream }
    func open() async throws {
        try await stream.connect(timeout: 10)
        let values: DTXValue = .dictionary(["com.apple.private.DTXBlockCompression": .integer(0), "com.apple.private.DTXConnection": .integer(1)])
        let id = nextID; nextID += 1
        try await stream.send(DTXCodec.encode(id: id, channel: 0, expectsReply: false, value: .string("_notifyOfPublishedCapabilities:"), arguments: [.object(values)]), timeout: 10)
        let deadline = Date().addingTimeInterval(15)
        for _ in 0..<64 {
            let message = try await DTXCodec.receive(from: stream, deadline: deadline)
            try await handle(message)
            if capabilities != nil { return }
        }
        throw TVPairError.malformed("Instruments capability handshake limit")
    }
    func channel(_ name: String) async throws -> Int32 {
        let code = nextChannel; nextChannel += 1
        let result = try await call(channel: 0, selector: "_requestChannelWithCode:identifier:", arguments: [.u32(UInt32(code)), .object(.string(name))])
        guard result == nil || result == .null else { throw TVPairError.unsupported("the device did not accept the requested Instruments channel") }
        return code
    }
    func call(channel: Int32, selector: String, arguments: [DTXArgument] = []) async throws -> DTXValue? {
        guard !calling else { throw TVPairError.malformed("concurrent Instruments request") }
        calling = true; defer { calling = false }
        let id = nextID; nextID += 1
        try await stream.send(DTXCodec.encode(id: id, channel: channel, value: .string(selector), arguments: arguments), timeout: 10)
        let deadline = Date().addingTimeInterval(15)
        for _ in 0..<128 {
            let message = try await DTXCodec.receive(from: stream, deadline: deadline)
            if message.identifier == id && message.conversation == 1 && message.channel == channel {
                if message.type == 4 { throw TVPairError.developer(message.value?.errorCode ?? -1) }
                if case let .some(.error(code)) = message.value { throw TVPairError.developer(code) }
                guard message.type == 0 || message.type == 3 else { throw TVPairError.malformed("Instruments reply type") }
                return message.value
            }
            try await handle(message)
        }
        throw TVPairError.malformed("Instruments reply limit")
    }
    private func handle(_ message: DTXMessage) async throws {
        let published = message.channel == 0 && message.value == .string("_notifyOfPublishedCapabilities:")
        if published {
            guard let values = message.arguments.first?.dictionary else { throw TVPairError.malformed("Instruments capabilities") }
            capabilities = values
        }
        if message.expectsReply {
            let reply = try DTXCodec.encode(id: message.identifier, channel: message.wireChannel, conversation: message.conversation + 1, expectsReply: false, type: published ? 0 : 4, value: published ? nil : .string("Unsupported TVPair callback"))
            try await stream.send(reply, timeout: 10)
        }
    }
}

private extension DTXValue {
    var errorCode: Int? { if case let .error(code) = self { return code }; return nil }
}

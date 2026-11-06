import Foundation

indirect enum OPACKValue: Equatable {
    case string(String), data(Data), integer(UInt64), bool(Bool), array([OPACKValue]), dictionary([String: OPACKValue]), null
    var string: String? { if case let .string(value) = self { return value }; return nil }
    var data: Data? { if case let .data(value) = self { return value }; return nil }
}

/// Bounded OPACK subset used for identity metadata. Unknown tags fail closed.
enum OPACK {
    static func encode(_ value: OPACKValue) throws -> Data {
        switch value {
        case let .string(string):
            let data = Data(string.utf8); return try length(data.count, base: 0x40, extended: 0x61) + data
        case let .data(data): return try length(data.count, base: 0x70, extended: 0x91) + data
        case let .bool(value): return Data([value ? 1 : 2])
        case .null: return Data([4])
        case let .integer(value):
            if value <= 39 { return Data([UInt8(value) + 8]) }
            var little = value.littleEndian
            return Data([0x33]) + withUnsafeBytes(of: &little) { Data($0) }
        case let .array(values):
            var output = Data([values.count < 15 ? 0xd0 + UInt8(values.count) : 0xdf])
            for value in values { output += try encode(value) }
            if values.count >= 15 { output.append(3) }; return output
        case let .dictionary(values):
            var output = Data([values.count < 15 ? 0xe0 + UInt8(values.count) : 0xef])
            for key in values.keys.sorted() { output += try encode(.string(key)); output += try encode(values[key]!) }
            if values.count >= 15 { output.append(3) }; return output
        }
    }
    private static func length(_ count: Int, base: UInt8, extended: UInt8) throws -> Data {
        guard count <= 65535 else { throw TVPairError.malformed("OPACK length limit") }
        if count <= 32 { return Data([base + UInt8(count)]) }
        if count <= 255 { return Data([extended, UInt8(count)]) }
        return Data([extended + 1, UInt8(count & 255), UInt8(count >> 8)])
    }
    static func decode(_ data: Data) throws -> OPACKValue {
        guard data.count <= 65535 else { throw TVPairError.malformed("OPACK size limit") }
        var decoder = Decoder(data: data)
        let value = try decoder.read(depth: 0)
        guard decoder.offset == data.count else { throw TVPairError.malformed("trailing OPACK data") }
        return value
    }
    private struct Decoder {
        let data: Data
        var offset = 0
        var objects: [OPACKValue] = []
        mutating func take(_ count: Int) throws -> Data {
            guard count >= 0, count <= data.count - offset else { throw TVPairError.malformed("truncated OPACK") }
            defer { offset += count }; return data.subdata(in: offset..<(offset + count))
        }
        mutating func integer(_ count: Int) throws -> UInt64 {
            try take(count).enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) }
        }
        mutating func remember(_ value: OPACKValue) -> OPACKValue {
            if !objects.contains(value) { objects.append(value) }; return value
        }
        mutating func read(depth: Int) throws -> OPACKValue {
            guard depth < 32 else { throw TVPairError.malformed("OPACK recursion limit") }
            let tag = try take(1)[0]
            switch tag {
            case 1: return .bool(true)
            case 2: return .bool(false)
            case 4: return .null
            case 5: return remember(.data(try take(16)))
            case 6: return remember(.data(try take(8)))
            case 8...0x2f: return .integer(UInt64(tag - 8))
            case 0x30...0x33: return remember(.integer(try integer(1 << Int(tag - 0x30))))
            case 0x35: return remember(.data(try take(4)))
            case 0x36: return remember(.data(try take(8)))
            case 0x40...0x64, 0x70...0x94:
                let isString = tag < 0x70, base: UInt8 = isString ? 0x40 : 0x70
                let extended: UInt8 = isString ? 0x61 : 0x91
                let size: UInt64 = tag < extended ? UInt64(tag - base) : try integer(1 << Int(tag - extended))
                guard size <= 65535 else { throw TVPairError.malformed("OPACK value size") }
                let bytes = try take(Int(size))
                if isString {
                    guard let string = String(data: bytes, encoding: .utf8) else { throw TVPairError.malformed("OPACK UTF-8") }
                    return remember(.string(string))
                }
                return remember(.data(bytes))
            case 0xa0...0xc4:
                let index = tag <= 0xc0 ? UInt64(tag - 0xa0) : try integer(1 << Int(tag - 0xc1))
                guard index < objects.count else { throw TVPairError.malformed("OPACK reference") }
                return objects[Int(index)]
            case 0xd0...0xdf, 0xe0...0xef:
                let dictionary = tag >= 0xe0, count = Int(tag & 15)
                var array: [OPACKValue] = [], pairs: [String: OPACKValue] = [:], seen = 0
                while count == 15 ? (offset < data.count && data[offset] != 3) : seen < count {
                    guard seen < 4096 else { throw TVPairError.malformed("OPACK collection size") }
                    let value = try read(depth: depth + 1)
                    if dictionary {
                        guard let key = value.string, pairs[key] == nil else { throw TVPairError.malformed("OPACK dictionary key") }
                        pairs[key] = try read(depth: depth + 1)
                    } else { array.append(value) }
                    seen += 1
                }
                if count == 15 { guard try take(1)[0] == 3 else { throw TVPairError.malformed("OPACK terminator") } }
                return dictionary ? .dictionary(pairs) : .array(array)
            default: throw TVPairError.unsupported("OPACK tag")
            }
        }
    }
}

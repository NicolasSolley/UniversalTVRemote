import Foundation

/// Minimal protobuf wire helpers — just enough for the Android TV Remote
/// protocol (varint + length-delimited fields). No generated code, no
/// dependencies.
enum Protobuf {
    // MARK: - Encoding

    /// Unsigned LEB128 varint.
    static func varint(_ value: UInt64) -> Data {
        var data = Data()
        var v = value
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            data.append(byte)
        } while v != 0
        return data
    }

    /// Field tag: (fieldNumber << 3) | wireType. Wire types: 0 = varint,
    /// 2 = length-delimited.
    static func tag(field: Int, wireType: Int) -> Data {
        varint(UInt64((field << 3) | wireType))
    }

    static func varintField(_ field: Int, _ value: UInt64) -> Data {
        tag(field: field, wireType: 0) + varint(value)
    }

    static func bytesField(_ field: Int, _ value: Data) -> Data {
        tag(field: field, wireType: 2) + varint(UInt64(value.count)) + value
    }

    static func stringField(_ field: Int, _ value: String) -> Data {
        bytesField(field, Data(value.utf8))
    }

    static func messageField(_ field: Int, _ value: Data) -> Data {
        bytesField(field, value)
    }

    // MARK: - Decoding

    struct Reader {
        let data: Data
        var offset: Int = 0

        var isAtEnd: Bool { offset >= data.count }

        mutating func readVarint() -> UInt64? {
            var result: UInt64 = 0
            var shift = 0
            while offset < data.count, shift < 70 {
                let byte = data[offset]
                offset += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
            return nil
        }

        mutating func readTag() -> (field: Int, wireType: Int)? {
            guard let raw = readVarint() else { return nil }
            return (Int(raw >> 3), Int(raw & 0x7))
        }

        mutating func readBytes() -> Data? {
            guard let length = readVarint(), length <= UInt64(data.count - offset) else { return nil }
            let end = offset + Int(length)
            let slice = data[offset..<end]
            offset = end
            return Data(slice)
        }

        mutating func readString() -> String? {
            guard let bytes = readBytes() else { return nil }
            return String(data: bytes, encoding: .utf8)
        }

        /// Skip one field of the given wire type.
        mutating func skipField(wireType: Int) -> Bool {
            switch wireType {
            case 0: return readVarint() != nil
            case 1: // 64-bit
                guard offset + 8 <= data.count else { return false }
                offset += 8
                return true
            case 2: return readBytes() != nil
            case 5: // 32-bit
                guard offset + 4 <= data.count else { return false }
                offset += 4
                return true
            default: return false
            }
        }
    }

    /// Read a varint length prefix from the front of `data`.
    /// Returns the message length and how many bytes the prefix consumed.
    static func readLengthPrefix(_ data: Data) -> (length: Int, prefixBytes: Int)? {
        var reader = Reader(data: data)
        guard let length = reader.readVarint() else { return nil }
        return (Int(length), reader.offset)
    }
}

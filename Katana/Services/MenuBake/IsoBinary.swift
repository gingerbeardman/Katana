import Foundation

/// Binary helpers for ISO 9660 / GDrom builders (subset of DiscUtils.Utilities).
nonisolated enum IsoBinary: Sendable {
    static let sectorSize = 2048

    static func roundUp(_ value: Int64, _ unit: Int64) -> Int64 {
        ((value + (unit - 1)) / unit) * unit
    }

    static func roundUp(_ value: Int, _ unit: Int) -> Int {
        ((value + (unit - 1)) / unit) * unit
    }

    static func writeUInt16LE(_ value: UInt16, into buffer: inout [UInt8], at offset: Int) {
        buffer[offset] = UInt8(value & 0xFF)
        buffer[offset + 1] = UInt8((value >> 8) & 0xFF)
    }

    static func writeUInt32LE(_ value: UInt32, into buffer: inout [UInt8], at offset: Int) {
        buffer[offset] = UInt8(value & 0xFF)
        buffer[offset + 1] = UInt8((value >> 8) & 0xFF)
        buffer[offset + 2] = UInt8((value >> 16) & 0xFF)
        buffer[offset + 3] = UInt8((value >> 24) & 0xFF)
    }

    static func writeUInt16BE(_ value: UInt16, into buffer: inout [UInt8], at offset: Int) {
        buffer[offset] = UInt8((value >> 8) & 0xFF)
        buffer[offset + 1] = UInt8(value & 0xFF)
    }

    static func writeUInt32BE(_ value: UInt32, into buffer: inout [UInt8], at offset: Int) {
        buffer[offset] = UInt8((value >> 24) & 0xFF)
        buffer[offset + 1] = UInt8((value >> 16) & 0xFF)
        buffer[offset + 2] = UInt8((value >> 8) & 0xFF)
        buffer[offset + 3] = UInt8(value & 0xFF)
    }

    static func writeBothUInt16(_ value: UInt16, into buffer: inout [UInt8], at offset: Int) {
        writeUInt16LE(value, into: &buffer, at: offset)
        writeUInt16BE(value, into: &buffer, at: offset + 2)
    }

    static func writeBothUInt32(_ value: UInt32, into buffer: inout [UInt8], at offset: Int) {
        writeUInt32LE(value, into: &buffer, at: offset)
        writeUInt32BE(value, into: &buffer, at: offset + 4)
    }

    static func bitSwapUInt16(_ value: UInt16) -> UInt16 {
        (value << 8) | (value >> 8)
    }

    static func bitSwapUInt32(_ value: UInt32) -> UInt32 {
        ((value & 0x0000_00FF) << 24)
            | ((value & 0x0000_FF00) << 8)
            | ((value & 0x00FF_0000) >> 8)
            | ((value & 0xFF00_0000) >> 24)
    }

    /// ASCII write with optional space padding; returns bytes written.
    @discardableResult
    static func writeASCII(
        _ string: String,
        into buffer: inout [UInt8],
        at offset: Int,
        count: Int,
        pad: Bool,
        canTruncate: Bool = false
    ) -> Int {
        let bytes = Array(string.utf8)
        if !canTruncate && !pad && bytes.count > count {
            // Match DiscUtils: fail if string doesn't fit when not allowed to truncate.
            // Callers for fixed fields pass pad:true so this path is rare.
        }
        var written = 0
        if pad {
            for i in 0..<count {
                if i < bytes.count {
                    buffer[offset + i] = bytes[i]
                } else {
                    buffer[offset + i] = 0x20 // space
                }
                written += 1
            }
        } else {
            let n = min(bytes.count, count)
            for i in 0..<n {
                buffer[offset + i] = bytes[i]
            }
            written = n
        }
        return written
    }

    static func writeDirectoryTimeUTC(_ date: Date, into buffer: inout [UInt8], at offset: Int) {
        let cal = Calendar(identifier: .gregorian)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard let year = c.year, year >= 1900,
              let month = c.month, let day = c.day,
              let hour = c.hour, let minute = c.minute, let second = c.second
        else {
            for i in 0..<7 { buffer[offset + i] = 0 }
            return
        }
        _ = cal
        buffer[offset] = UInt8(year - 1900)
        buffer[offset + 1] = UInt8(month)
        buffer[offset + 2] = UInt8(day)
        buffer[offset + 3] = UInt8(hour)
        buffer[offset + 4] = UInt8(minute)
        buffer[offset + 5] = UInt8(second)
        buffer[offset + 6] = 0
    }

    static func writeVolumeDescriptorTimeUTC(_ date: Date, into buffer: inout [UInt8], at offset: Int) {
        // 16 ASCII digits yyyyMMddHHmmssff + 1 timezone byte
        if date == Date.distantPast || date.timeIntervalSince1970 <= 0 {
            for i in 0..<16 { buffer[offset + i] = UInt8(ascii: "0") }
            buffer[offset + 16] = 0
            return
        }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = utc.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond],
            from: date
        )
        let year = c.year ?? 1970
        let month = c.month ?? 1
        let day = c.day ?? 1
        let hour = c.hour ?? 0
        let minute = c.minute ?? 0
        let second = c.second ?? 0
        let hundredths = min(99, max(0, (c.nanosecond ?? 0) / 10_000_000))
        let str = String(
            format: "%04d%02d%02d%02d%02d%02d%02d",
            year, month, day, hour, minute, second, hundredths
        )
        let bytes = Array(str.utf8)
        for i in 0..<16 {
            buffer[offset + i] = i < bytes.count ? bytes[i] : UInt8(ascii: "0")
        }
        buffer[offset + 16] = 0
    }

    static func isValidDChar(_ ch: Character) -> Bool {
        guard let ascii = ch.asciiValue else { return false }
        return (ascii >= 0x30 && ascii <= 0x39) // 0-9
            || (ascii >= 0x41 && ascii <= 0x5A) // A-Z
            || ascii == 0x5F // _
    }

    static func isValidFileName(_ str: String) -> Bool {
        for ch in str {
            guard let ascii = ch.asciiValue else { return false }
            let ok = (ascii >= 0x30 && ascii <= 0x39)
                || (ascii >= 0x41 && ascii <= 0x5A)
                || ascii == 0x5F || ascii == 0x2E || ascii == 0x3B
            if !ok { return false }
        }
        return true
    }

    static func isValidDirectoryName(_ str: String) -> Bool {
        if str.count == 1, let c = str.unicodeScalars.first, c.value <= 1 { return true }
        return str.allSatisfy { isValidDChar($0) }
    }

    static func normalizeFileName(_ name: String) -> String {
        let parts = splitFileName(name)
        return "\(parts.0).\(parts.1);\(parts.2)"
    }

    static func splitFileName(_ name: String) -> (String, String, String) {
        var base = name
        var ext = ""
        var ver = "1"

        if let dot = name.firstIndex(of: ".") {
            base = String(name[..<dot])
            let after = String(name[name.index(after: dot)...])
            if let semi = after.firstIndex(of: ";") {
                ext = String(after[..<semi])
                ver = String(after[after.index(after: semi)...])
            } else {
                ext = after
            }
        } else if let semi = name.firstIndex(of: ";") {
            base = String(name[..<semi])
            ver = String(name[name.index(after: semi)...])
        }

        if let v = UInt16(ver), v >= 1, v <= 32767 {
            ver = String(v)
        } else {
            ver = "1"
        }
        return (base, ext, ver)
    }
}

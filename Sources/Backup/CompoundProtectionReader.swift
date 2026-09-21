import Foundation

/// Reads CFB allocation/directory metadata, never the encrypted document stream.
/// MS-OFFCRYPTO IRMDS uses DRMEncryptedTransform / DRMEncryptedDataSpace;
/// password-only encryption uses different directory names.
struct CompoundProtectionReader {
    let file: FileHandle

    enum ParseError: Error, LocalizedError {
        case malformed
        var errorDescription: String? { "Invalid or oversized compound-file protection metadata" }
    }

    private func read(at offset: UInt64, count: Int) throws -> Data {
        try file.seek(toOffset: offset)
        let data = try file.read(upToCount: count) ?? Data()
        guard data.count == count else { throw ParseError.malformed }
        return data
    }

    private func uint16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }

    func isRightsManaged() throws -> Bool {
        let header = try read(at: 0, count: 512)
        let majorVersion = uint16(header, 26)
        let shift = uint16(header, 30)
        guard uint16(header, 28) == 0xfffe,
              (majorVersion == 3 && shift == 9) || (majorVersion == 4 && shift == 12) else {
            throw ParseError.malformed
        }
        let sectorSize = 1 << Int(shift)
        let fileSize = try file.seekToEnd()
        guard fileSize >= UInt64(sectorSize) else { throw ParseError.malformed }
        let sectorCount = fileSize / UInt64(sectorSize) - 1
        let end: UInt32 = 0xfffffffe
        let free: UInt32 = 0xffffffff

        func sector(_ id: UInt32) throws -> Data {
            guard UInt64(id) < sectorCount else { throw ParseError.malformed }
            return try read(at: (UInt64(id) + 1) * UInt64(sectorSize), count: sectorSize)
        }

        let fatCount = Int(uint32(header, 44))
        guard fatCount > 0, UInt64(fatCount) <= sectorCount, fatCount <= 1_048_576 else {
            throw ParseError.malformed
        }
        var fatSectors: [UInt32] = []
        func appendFAT(from data: Data, start: Int, count: Int) throws {
            for offset in stride(from: start, to: start + count * 4, by: 4) {
                let id = uint32(data, offset)
                if id == free { continue }
                guard UInt64(id) < sectorCount, fatSectors.count < fatCount else {
                    throw ParseError.malformed
                }
                fatSectors.append(id)
            }
        }
        try appendFAT(from: header, start: 76, count: 109)
        var difat = uint32(header, 68)
        let difatCount = Int(uint32(header, 72))
        guard UInt64(difatCount) <= sectorCount, difatCount <= 16_384 else {
            throw ParseError.malformed
        }
        var seenDIFAT: Set<UInt32> = []
        for _ in 0..<difatCount {
            guard seenDIFAT.insert(difat).inserted else { throw ParseError.malformed }
            let data = try sector(difat)
            try appendFAT(from: data, start: 0, count: sectorSize / 4 - 1)
            difat = uint32(data, sectorSize - 4)
        }
        guard fatSectors.count == fatCount,
              difatCount == 0 || difat == end else { throw ParseError.malformed }

        var cachedFATIndex: Int?
        var cachedFAT = Data()
        func nextSector(after id: UInt32) throws -> UInt32 {
            let index = Int(id) / (sectorSize / 4)
            guard index < fatSectors.count else { throw ParseError.malformed }
            if cachedFATIndex != index {
                cachedFAT = try sector(fatSectors[index])
                cachedFATIndex = index
            }
            return uint32(cachedFAT, (Int(id) % (sectorSize / 4)) * 4)
        }

        var directory = uint32(header, 48)
        var visited: Set<UInt32> = []
        while directory != end {
            guard visited.count < 16_384, visited.insert(directory).inserted else {
                throw ParseError.malformed
            }
            let data = try sector(directory)
            for offset in stride(from: 0, to: sectorSize, by: 128) {
                let type = data[offset + 66]
                if type == 0 { continue }
                guard [1, 2, 5].contains(type) else { throw ParseError.malformed }
                let length = Int(uint16(data, offset + 64))
                guard length >= 2, length <= 64, length % 2 == 0 else { throw ParseError.malformed }
                let nameData = data.subdata(in: offset..<(offset + length - 2))
                guard let name = String(data: nameData, encoding: .utf16LittleEndian) else {
                    throw ParseError.malformed
                }
                if (type == 1 && name == "DRMEncryptedTransform")
                    || (type == 2 && name == "DRMEncryptedDataSpace") {
                    return true
                }
            }
            directory = try nextSector(after: directory)
        }
        return false
    }
}

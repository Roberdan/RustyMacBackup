import Foundation

/// Streaming PDF name-token inspection. Scans the whole file (metadata need not be
/// at the head/tail), ignoring comments, strings and stream payloads.
/// This recognizes Microsoft's RMS security handler, not password-only /Standard.
enum PDFRightsProtection {
    static func containsProtection(in file: FileHandle) throws -> Bool {
        var token: [UInt8] = []
        var readingName = false
        var expectsFilter = false
        var expectsFileName = false
        var stringDepth = 0
        var fileName: [UInt8] = []
        var escaped = false
        var comment = false
        var hexString = false
        var pendingLess = false
        var inStream = false
        var streamTail: [UInt8] = []
        let streamEnd = Array("endstream".utf8)
        let whitespace: Set<UInt8> = [0, 9, 10, 12, 13, 32]
        let delimiters: Set<UInt8> = [40, 41, 60, 62, 91, 93, 123, 125, 47, 37]

        func decodedName(_ bytes: [UInt8]) -> String {
            var decoded: [UInt8] = []
            var index = 0
            while index < bytes.count {
                if bytes[index] == 35, index + 2 < bytes.count,
                   let value = UInt8(String(decoding: bytes[(index + 1)...(index + 2)], as: UTF8.self), radix: 16) {
                    decoded.append(value)
                    index += 3
                } else {
                    decoded.append(bytes[index])
                    index += 1
                }
            }
            return String(decoding: decoded, as: UTF8.self)
        }

        func finishToken() -> Bool {
            guard !token.isEmpty else { return false }
            defer { token.removeAll(keepingCapacity: true); readingName = false }
            if readingName {
                let name = decodedName(token)
                if expectsFilter && name == "MicrosoftIRMServices" { return true }
                expectsFilter = name == "Filter"
                expectsFileName = name == "F" || name == "UF"
            } else {
                expectsFilter = false
                expectsFileName = false
                if token == Array("stream".utf8) { inStream = true }
            }
            return false
        }

        while let data = try file.read(upToCount: 65_536), !data.isEmpty {
            for byte in data {
                if inStream {
                    streamTail.append(byte)
                    if streamTail.count > streamEnd.count { streamTail.removeFirst() }
                    if streamTail == streamEnd {
                        inStream = false
                        streamTail.removeAll(keepingCapacity: true)
                    }
                    continue
                }
                if comment {
                    if byte == 10 || byte == 13 { comment = false }
                    continue
                }
                if stringDepth > 0 {
                    if escaped {
                        if fileName.count < 256 { fileName.append(byte) }
                        escaped = false
                    }
                    else if byte == 92 { escaped = true }
                    else if byte == 40 {
                        stringDepth += 1
                        if fileName.count < 256 { fileName.append(byte) }
                    }
                    else if byte == 41 {
                        stringDepth -= 1
                        if stringDepth == 0 {
                            // Legacy RMS PDFs wrap the encrypted PDF as this attachment.
                            if expectsFileName && String(decoding: fileName, as: UTF8.self)
                                == "MicrosoftIRMServices Protected PDF.pdf" { return true }
                            expectsFileName = false
                        } else if fileName.count < 256 { fileName.append(byte) }
                    }
                    else if fileName.count < 256 { fileName.append(byte) }
                    continue
                }
                if hexString {
                    if byte == 62 { hexString = false }
                    continue
                }
                if pendingLess {
                    pendingLess = false
                    if byte == 60 { continue }
                    hexString = byte != 62
                    continue
                }
                if whitespace.contains(byte) || delimiters.contains(byte) {
                    if finishToken() { return true }
                    switch byte {
                    case 47: readingName = true
                    case 37: comment = true
                    case 40:
                        stringDepth = 1
                        fileName.removeAll(keepingCapacity: true)
                        expectsFilter = false
                    case 60: pendingLess = true; expectsFilter = false; expectsFileName = false
                    default:
                        if !whitespace.contains(byte) { expectsFilter = false; expectsFileName = false }
                    }
                } else {
                    // No recognized name/operator is long. Bound memory on hostile input.
                    if token.count < 256 { token.append(byte) }
                    else { expectsFilter = false; readingName = false }
                }
            }
        }
        return finishToken()
    }
}

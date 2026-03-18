import Cocoa
import UserNotifications

// MARK: - Maranello Luce Design Colors (from tokens-color.css)

enum MLColor {
    // Primary Ferrari palette
    static let gold    = NSColor(red: 0xFF/255, green: 0xC7/255, blue: 0x2C/255, alpha: 1) // --giallo-ferrari
    static let rosso   = NSColor(red: 0xDC/255, green: 0x00/255, blue: 0x00/255, alpha: 1) // --rosso-corsa
    static let verde   = NSColor(red: 0x00/255, green: 0xA6/255, blue: 0x51/255, alpha: 1) // --verde-racing
    static let nero    = NSColor(red: 0x11/255, green: 0x11/255, blue: 0x11/255, alpha: 1) // --nero-carbon
    static let avorio  = NSColor(red: 0xFA/255, green: 0xF3/255, blue: 0xE6/255, alpha: 1) // --avorio-chiaro
    // Extended palette
    static let goldLight  = NSColor(red: 0xFF/255, green: 0xD8/255, blue: 0x5C/255, alpha: 1) // --giallo-ferrari-light
    static let verdeLt    = NSColor(red: 0x00/255, green: 0xC9/255, blue: 0x66/255, alpha: 1) // --verde-racing-light
    static let arancio    = NSColor(red: 0xD4/255, green: 0x62/255, blue: 0x2B/255, alpha: 1) // --arancio-warm
    static let info       = NSColor(red: 0x44/255, green: 0x8A/255, blue: 0xFF/255, alpha: 1) // --status-info
    static let warning    = NSColor(red: 0xFF/255, green: 0xB3/255, blue: 0x00/255, alpha: 1) // --status-warning
    static let grigio     = NSColor(red: 0x9E/255, green: 0x9E/255, blue: 0x9E/255, alpha: 1) // --grigio-chiaro / --mn-text-muted
    static let dimmed  = NSColor.secondaryLabelColor
}

// MARK: - Attributed String Helpers

enum MLText {
    static let headerFont = NSFont.boldSystemFont(ofSize: 13)
    static let bodyFont   = NSFont.menuFont(ofSize: 13)
    static let smallFont  = NSFont.menuFont(ofSize: 11)
    static let boldFont   = NSFont.boldSystemFont(ofSize: 13)

    static func header(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: headerFont])
    }

    static func plain(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: bodyFont])
    }

    static func colored(_ text: String, _ color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: bodyFont, .foregroundColor: color])
    }

    static func bold(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: boldFont])
    }

    static func small(_ text: String, _ color: NSColor = MLColor.dimmed) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: smallFont, .foregroundColor: color])
    }

    static func dot(_ color: NSColor) -> NSAttributedString {
        colored("\u{25CF} ", color)
    }

    static func smallDot(_ color: NSColor) -> NSAttributedString {
        NSAttributedString(string: "\u{25CF} ", attributes: [.font: smallFont, .foregroundColor: color])
    }

    static func build(_ parts: NSAttributedString...) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for part in parts { result.append(part) }
        return result
    }

    // Maranello-correct progress bar: monochrome accent gold
    static func tachometer(pct: Int, width: Int = 25) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let filled = pct * width / 100
        let monoFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)

        // Solid gold fill + muted empty — clean Ferrari Luce style
        if filled > 0 {
            result.append(NSAttributedString(string: String(repeating: "\u{2589}", count: filled),
                attributes: [.font: monoFont, .foregroundColor: MLColor.gold]))
        }
        let remain = width - filled
        if remain > 0 {
            result.append(NSAttributedString(string: String(repeating: "\u{2581}", count: remain),
                attributes: [.font: monoFont, .foregroundColor: MLColor.grigio.withAlphaComponent(0.25)]))
        }

        // Percentage in primary text
        result.append(NSAttributedString(string: " \(pct)%",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]))

        return result
    }

    // Clean up ugly paths (remove GUIDs, shorten)
    static func cleanPath(_ path: String) -> String {
        let components = path.split(separator: "/")
        // Filter out GUID-like components
        let cleaned = components.filter { comp in
            let s = String(comp)
            // Skip if looks like a GUID: 8-4-4-4-12 hex
            if s.count > 30 && s.contains("-") {
                let parts = s.split(separator: "-")
                if parts.count >= 4 && parts.allSatisfy({ $0.allSatisfy { $0.isHexDigit } }) {
                    return false
                }
            }
            // Skip .dat/.db numeric suffixes
            if s.hasPrefix("_") && s.count > 20 { return false }
            return true
        }
        // Show last 2-3 meaningful components
        let meaningful = Array(cleaned.suffix(3))
        return meaningful.joined(separator: " / ")
    }
}

// MARK: - Status Model

struct BackupStatus: Codable {
    let state: String
    let started_at: String?
    let last_completed: String?
    let last_duration_secs: Double?
    let files_total: Int?
    let files_done: Int?
    let bytes_copied: Int64?
    let bytes_per_sec: Int64?
    let eta_secs: Int?
    let errors: Int?
    let current_file: String?
}

// MARK: - Mini Speedometer View (Maranello Ferrari Gauge Style)

class ProgressBarView: NSView {
    var percent: Double = 0
    var label: String = ""

    override var intrinsicContentSize: NSSize {
        return NSSize(width: 250, height: 32)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let barX: CGFloat = 14
        let barY: CGFloat = 10
        let barW: CGFloat = bounds.width - 70
        let barH: CGFloat = 12
        let cornerR: CGFloat = barH / 2

        // Background track
        let bgPath = CGPath(roundedRect: CGRect(x: barX, y: barY, width: barW, height: barH),
                            cornerWidth: cornerR, cornerHeight: cornerR, transform: nil)
        ctx.addPath(bgPath)
        ctx.setFillColor(NSColor(white: 0.2, alpha: 0.5).cgColor)
        ctx.fillPath()

        // Filled portion with gradient: rosso → gold → verde
        let fillW = max(barW * CGFloat(percent) / 100.0, cornerR * 2)
        if percent > 0 {
            let fillRect = CGRect(x: barX, y: barY, width: fillW, height: barH)
            let fillPath = CGPath(roundedRect: fillRect,
                                  cornerWidth: cornerR, cornerHeight: cornerR, transform: nil)

            ctx.saveGState()
            ctx.addPath(fillPath)
            ctx.clip()

            // Gradient: rosso(left) → gold(mid) → verde(right)
            let colors = [
                CGColor(red: 0.86, green: 0, blue: 0, alpha: 1.0),       // rosso corsa
                CGColor(red: 1.0, green: 0.78, blue: 0.17, alpha: 1.0),  // giallo ferrari
                CGColor(red: 0, green: 0.65, blue: 0.32, alpha: 1.0),    // verde racing
            ] as CFArray
            let locations: [CGFloat] = [0.0, 0.5, 1.0]

            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                          colors: colors, locations: locations) {
                ctx.drawLinearGradient(gradient,
                    start: CGPoint(x: barX, y: barY),
                    end: CGPoint(x: barX + barW, y: barY),
                    options: [])
            }
            ctx.restoreGState()
        }

        // Percentage text to the right
        let pctStr = "\(Int(percent))%"
        let pctFont = NSFont.boldSystemFont(ofSize: 13)
        let pctAttrs: [NSAttributedString.Key: Any] = [
            .font: pctFont, .foregroundColor: NSColor.labelColor
        ]
        let pctSize = (pctStr as NSString).size(withAttributes: pctAttrs)
        (pctStr as NSString).draw(
            at: CGPoint(x: barX + barW + 8, y: barY + (barH - pctSize.height) / 2),
            withAttributes: pctAttrs)
    }
}

class SpeedometerView: NSView {
    var speedMBps: Double = 0
    var maxSpeed: Double = 100
    var etaText: String = ""

    override var intrinsicContentSize: NSSize {
        return NSSize(width: 220, height: 90)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let gaugeSize: CGFloat = 76
        let centerX: CGFloat = gaugeSize / 2 + 12
        let centerY: CGFloat = gaugeSize / 2 + 2
        let radius: CGFloat = gaugeSize / 2 - 6

        // Arc: 210° to -30° (240° sweep, open bottom)
        let startAngle: CGFloat = 210 * .pi / 180
        let endAngle: CGFloat = -30 * .pi / 180
        let totalSweep: CGFloat = 240

        // Background arc
        ctx.setStrokeColor(NSColor(white: 0.25, alpha: 0.5).cgColor)
        ctx.setLineWidth(5)
        ctx.addArc(center: CGPoint(x: centerX, y: centerY), radius: radius,
                   startAngle: startAngle, endAngle: endAngle, clockwise: true)
        ctx.strokePath()

        // Active arc — gold
        let valuePct = min(speedMBps / maxSpeed, 1.0)
        let valueAngle = startAngle - CGFloat(valuePct * Double(totalSweep)) * .pi / 180

        if valuePct > 0.01 {
            ctx.setStrokeColor(CGColor(red: 1.0, green: 0.78, blue: 0.17, alpha: 1.0))
            ctx.setLineWidth(5)
            ctx.addArc(center: CGPoint(x: centerX, y: centerY), radius: radius,
                       startAngle: startAngle, endAngle: valueAngle, clockwise: true)
            ctx.strokePath()
        }

        // Tick marks: 0, 25, 50, 75, 100
        for i in 0...4 {
            let tickPct = Double(i) / 4.0
            let tickAngle = startAngle - CGFloat(tickPct * Double(totalSweep)) * .pi / 180
            let inner = radius - 8
            let outer = radius + 1
            ctx.setStrokeColor(NSColor(white: 0.45, alpha: 0.6).cgColor)
            ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: centerX + cos(tickAngle) * inner,
                                  y: centerY + sin(tickAngle) * inner))
            ctx.addLine(to: CGPoint(x: centerX + cos(tickAngle) * outer,
                                     y: centerY + sin(tickAngle) * outer))
            ctx.strokePath()

            // Tick labels
            let label = "\(i * 25)"
            let labelFont = NSFont.systemFont(ofSize: 7, weight: .medium)
            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: labelFont,
                .foregroundColor: NSColor(white: 0.5, alpha: 0.7)
            ]
            let labelSize = (label as NSString).size(withAttributes: labelAttrs)
            let labelR = radius + 8
            let lx = centerX + cos(tickAngle) * labelR - labelSize.width / 2
            let ly = centerY + sin(tickAngle) * labelR - labelSize.height / 2
            (label as NSString).draw(at: CGPoint(x: lx, y: ly), withAttributes: labelAttrs)
        }

        // Needle — rosso corsa
        let needleLen = radius - 14
        let nx = centerX + cos(valueAngle) * needleLen
        let ny = centerY + sin(valueAngle) * needleLen
        ctx.setStrokeColor(CGColor(red: 0.86, green: 0, blue: 0, alpha: 1.0))
        ctx.setLineWidth(2)
        ctx.move(to: CGPoint(x: centerX, y: centerY))
        ctx.addLine(to: CGPoint(x: nx, y: ny))
        ctx.strokePath()

        // Center hub
        ctx.setFillColor(CGColor(red: 0.86, green: 0, blue: 0, alpha: 1.0))
        ctx.fillEllipse(in: CGRect(x: centerX - 3, y: centerY - 3, width: 6, height: 6))

        // Speed value — bold center
        let speedStr = String(format: "%.0f", speedMBps)
        let speedFont = NSFont.boldSystemFont(ofSize: 16)
        let speedAttrs: [NSAttributedString.Key: Any] = [
            .font: speedFont, .foregroundColor: NSColor.labelColor
        ]
        let speedSize = (speedStr as NSString).size(withAttributes: speedAttrs)
        (speedStr as NSString).draw(
            at: CGPoint(x: centerX - speedSize.width / 2, y: centerY - speedSize.height / 2 - 5),
            withAttributes: speedAttrs)

        // "MB/s" unit
        let unitAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 7, weight: .medium),
            .foregroundColor: NSColor(white: 0.55, alpha: 1.0)
        ]
        let unitSize = ("MB/s" as NSString).size(withAttributes: unitAttrs)
        ("MB/s" as NSString).draw(
            at: CGPoint(x: centerX - unitSize.width / 2, y: centerY - speedSize.height / 2 - 16),
            withAttributes: unitAttrs)

        // ETA to the right of the gauge
        if !etaText.isEmpty {
            let rightX: CGFloat = gaugeSize + 24
            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor(white: 0.55, alpha: 1.0)
            ]
            let valueAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 13),
                .foregroundColor: NSColor(red: 1.0, green: 0.78, blue: 0.17, alpha: 1.0)
            ]
            ("finisce tra" as NSString).draw(at: CGPoint(x: rightX, y: 50), withAttributes: labelAttrs)
            (etaText as NSString).draw(at: CGPoint(x: rightX, y: 30), withAttributes: valueAttrs)
        }
    }
}

// MARK: - Formatting Helpers

enum Fmt {
    static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let isoFormatterNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let localFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let localWithTZFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func parseISO(_ s: String) -> Date? {
        return isoFormatter.date(from: s)
            ?? isoFormatterNoFrac.date(from: s)
            ?? localWithTZFormatter.date(from: s)
            ?? localFormatter.date(from: s)
    }

    static func relativeTime(from date: Date) -> String {
        let secs = Int(-date.timeIntervalSinceNow)
        if secs < 60 { return "adesso" }
        if secs < 3600 {
            let m = secs / 60
            return "\(m) minut\(m == 1 ? "o" : "i") fa"
        }
        if secs < 86400 {
            let h = secs / 3600
            let m = (secs % 3600) / 60
            if m > 0 {
                return "\(h) or\(h == 1 ? "a" : "e") e \(m) min fa"
            }
            return "\(h) or\(h == 1 ? "a" : "e") fa"
        }
        let d = secs / 86400
        if d == 1 { return "ieri" }
        return "\(d) giorni fa"
    }

    static func duration(_ secs: Double) -> String {
        let total = Int(secs)
        if total < 60 { return "\(total) secondi" }
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            if m > 0 { return "circa \(h) or\(h == 1 ? "a" : "e") e \(m) min" }
            return "circa \(h) or\(h == 1 ? "a" : "e")"
        }
        if s > 0 && m < 10 { return "\(m) min \(s) sec" }
        return "\(m) minuti"
    }

    static func number(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    static func bytes(_ b: Int64) -> String {
        let bf = ByteCountFormatter()
        bf.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        bf.countStyle = .file
        return bf.string(fromByteCount: b)
    }

    static func speed(_ bps: Int64) -> String {
        let mbps = Double(bps) / (1024 * 1024)
        if mbps >= 1000 {
            return String(format: "%.1f GB/s", mbps / 1024)
        } else if mbps >= 1 {
            return String(format: "%.1f MB/s", mbps)
        }
        return "\(bytes(bps))/s"
    }

    static func timeUntil(minutes: Int, lastCompleted: Date?) -> String {
        guard let last = lastCompleted else { return "not scheduled" }
        let next = last.addingTimeInterval(Double(minutes * 60))
        let remaining = Int(next.timeIntervalSinceNow)
        if remaining <= 0 { return "due now" }
        if remaining < 60 { return "in \(remaining)s" }
        return "in \(remaining / 60) min"
    }
}

// MARK: - Shell Runner

enum Shell {
    private static let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    private static let pathPrefix = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin"

    @discardableResult
    static func run(_ command: String) -> String {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-c", "export PATH=\"\(pathPrefix):$PATH\"; \(command)"]
        task.standardOutput = pipe
        task.standardError = pipe
        task.environment = ProcessInfo.processInfo.environment
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return "error: \(error.localizedDescription)"
        }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func runAsync(_ command: String, completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = run(command)
            DispatchQueue.main.async { completion(result) }
        }
    }
}

// MARK: - Config Manager

struct ParsedConfig {
    var sourcePath: String = ""
    var extraPaths: [String] = []
    var destPath: String = ""
    var excludePatterns: [String] = []
    var hourly: Int = 24
    var daily: Int = 30
    var weekly: Int = 52
    var monthly: Int = 0

    var allSourcePaths: [String] {
        var paths = [sourcePath]
        paths.append(contentsOf: extraPaths)
        return paths.filter { !$0.isEmpty }
    }
}

enum ConfigManager {
    private static let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    static let configPath = "\(home)/.config/rusty-mac-backup/config.toml"

    static func load() -> ParsedConfig {
        guard let content = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return ParsedConfig()
        }
        return parseTOML(content)
    }

    private static func parseTOML(_ content: String) -> ParsedConfig {
        var config = ParsedConfig()
        var section = ""
        var inArray = false
        var arrayKey = ""
        var arrayValues: [String] = []

        for rawLine in content.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                if inArray && trimmed.hasPrefix("#") { continue }
                if !inArray { continue }
                continue
            }

            if trimmed.hasPrefix("[") && !trimmed.hasPrefix("[[") && trimmed.hasSuffix("]") && !inArray {
                section = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                continue
            }

            if inArray {
                if trimmed.hasPrefix("]") {
                    switch "\(section).\(arrayKey)" {
                    case "source.extra_paths": config.extraPaths = arrayValues
                    case "exclude.patterns": config.excludePatterns = arrayValues
                    default: break
                    }
                    inArray = false
                    arrayValues = []
                    continue
                }
                if let val = extractQuoted(trimmed) {
                    arrayValues.append(val)
                }
                continue
            }

            guard let eqIdx = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eqIdx]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces)

            if let commentRange = value.range(of: " #") {
                value = String(value[..<commentRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            }

            if value.hasPrefix("[") && !value.hasSuffix("]") {
                inArray = true
                arrayKey = key
                arrayValues = []
                continue
            }

            if value.hasPrefix("[") && value.hasSuffix("]") {
                let inner = String(value.dropFirst().dropLast())
                let vals = inner.components(separatedBy: ",").compactMap { extractQuoted($0) }
                switch "\(section).\(key)" {
                case "source.extra_paths": config.extraPaths = vals
                case "exclude.patterns": config.excludePatterns = vals
                default: break
                }
                continue
            }

            switch "\(section).\(key)" {
            case "source.path": config.sourcePath = extractQuoted(value) ?? value
            case "destination.path": config.destPath = extractQuoted(value) ?? value
            case "retention.hourly": config.hourly = Int(value) ?? 24
            case "retention.daily": config.daily = Int(value) ?? 30
            case "retention.weekly": config.weekly = Int(value) ?? 52
            case "retention.monthly": config.monthly = Int(value) ?? 0
            default: break
            }
        }
        return config
    }

    private static func extractQuoted(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: CharacterSet(charactersIn: " ,\t"))
        guard t.count >= 2, t.hasPrefix("\""), t.hasSuffix("\"") else { return nil }
        return String(t.dropFirst().dropLast())
    }

    // MARK: Extra Paths Management

    static func addExtraPath(_ path: String) {
        guard var content = try? String(contentsOfFile: configPath, encoding: .utf8) else { return }
        if let range = content.range(of: "extra_paths") {
            var searchStart = range.upperBound
            if let bracketStart = content.range(of: "[", range: searchStart..<content.endIndex) {
                searchStart = bracketStart.upperBound
            }
            if let closeRange = content.range(of: "]", range: searchStart..<content.endIndex) {
                let insertion = "    \"\(path)\",\n"
                content.insert(contentsOf: insertion, at: closeRange.lowerBound)
                try? content.write(toFile: configPath, atomically: true, encoding: .utf8)
            }
        } else {
            // No extra_paths yet — add after the path line in [source]
            let searchStart: String.Index
            if let sourceRange = content.range(of: "[source]") {
                searchStart = sourceRange.upperBound
            } else {
                searchStart = content.startIndex
            }
            if let pathLine = content.range(of: "path = ", range: searchStart..<content.endIndex) {
                if let lineEnd = content.range(of: "\n", range: pathLine.upperBound..<content.endIndex) {
                    let insertion = "extra_paths = [\n    \"\(path)\",\n]\n"
                    content.insert(contentsOf: insertion, at: lineEnd.upperBound)
                    try? content.write(toFile: configPath, atomically: true, encoding: .utf8)
                }
            }
        }
    }

    static func removeExtraPath(_ path: String) {
        guard var content = try? String(contentsOfFile: configPath, encoding: .utf8) else { return }
        let escaped = path.replacingOccurrences(of: "/", with: "\\/")
        let _ = escaped // suppress unused warning
        let patterns = [
            "    \"\(path)\",\n",
            "    \"\(path)\"\n",
            "    \"\(path)\",",
            "    \"\(path)\"",
        ]
        for p in patterns {
            if content.contains(p) {
                content = content.replacingOccurrences(of: p, with: "")
                break
            }
        }
        try? content.write(toFile: configPath, atomically: true, encoding: .utf8)
    }
}

// MARK: - Volume Scanner

struct VolumeInfo {
    let name: String
    let path: String
    let freeSpace: Int64
    let isEncrypted: Bool

    var freeSpaceFormatted: String { Fmt.bytes(freeSpace) }
    var encryptionLabel: String { isEncrypted ? "Encrypted" : "Not encrypted" }
}

enum VolumeScanner {
    static func connectedVolumes() -> [VolumeInfo] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: "/Volumes") else { return [] }

        return entries.sorted().compactMap { name -> VolumeInfo? in
            guard !name.hasPrefix("."),
                  name != "Macintosh HD",
                  name != "Recovery" else { return nil }
            let volumePath = "/Volumes/\(name)"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: volumePath, isDirectory: &isDir), isDir.boolValue else { return nil }

            let url = URL(fileURLWithPath: volumePath)
            let free: Int64
            if let vals = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
               let f = vals.volumeAvailableCapacityForImportantUsage {
                free = f
            } else {
                free = 0
            }

            let encrypted = checkEncryption(volumePath)
            return VolumeInfo(name: name, path: volumePath, freeSpace: free, isEncrypted: encrypted)
        }
    }

    static func checkEncryption(_ volumePath: String) -> Bool {
        let output = Shell.run("diskutil info \"\(volumePath)\" 2>/dev/null")
        let lower = output.lowercased()
        return lower.contains("filevault: yes")
            || lower.contains("encrypted: yes")
            || (lower.contains("file system personality") && lower.contains("encrypted"))
    }
}

// MARK: - Disk Info

struct DiskDetail {
    let volumeName: String
    let freeSpace: String
    let isEncrypted: Bool

    var summary: String {
        "\(volumeName) -- \(freeSpace) free"
    }
}

enum DiskInfo {
    static func detail(for config: ParsedConfig) -> DiskDetail? {
        let destPath = config.destPath
        guard !destPath.isEmpty else { return nil }

        let volumeName: String
        let volumeRoot: String
        if destPath.hasPrefix("/Volumes/") {
            let parts = destPath.split(separator: "/", maxSplits: 3)
            volumeName = parts.count >= 2 ? String(parts[1]) : "Unknown"
            volumeRoot = "/Volumes/\(volumeName)"
        } else {
            volumeName = "Macintosh HD"
            volumeRoot = "/"
        }

        let url = URL(fileURLWithPath: volumeRoot)
        var free: Int64 = 0
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let cap = values.volumeAvailableCapacityForImportantUsage, cap > 0 {
            free = cap
        } else if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
                  let cap = values.volumeAvailableCapacity, cap > 0 {
            free = Int64(cap)
        } else {
            // Fallback: use df command
            let dfOutput = Shell.run("df -k '\(volumeRoot)' | tail -1 | awk '{print $4}'")
            if let kb = Int64(dfOutput.trimmingCharacters(in: .whitespacesAndNewlines)) {
                free = kb * 1024
            }
        }

        guard free > 0 else { return nil }

        let encrypted = VolumeScanner.checkEncryption(volumeRoot)
        return DiskDetail(volumeName: volumeName, freeSpace: Fmt.bytes(free), isEncrypted: encrypted)
    }

    static func freeSpace() -> String? {
        return detail(for: ConfigManager.load())?.freeSpace
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var pollTimer: Timer?
    private var animationTimer: Timer?
    private var animationFrame: Int = 0

    private var currentStatus: BackupStatus?
    private var previousState: String = "idle"
    private var wasDiskConnected: Bool = false
    private var scheduleIntervalMinutes: Int = 60
    private var scheduleEnabled: Bool = true
    private var cachedConfig: ParsedConfig = ParsedConfig()
    private var cachedDiskDetail: DiskDetail?
    private var diskDetailLastChecked: Date = .distantPast

    private var isDiskConnected: Bool {
        let dest = cachedConfig.destPath
        guard !dest.isEmpty else { return false }
        // Check if the volume root exists
        if dest.hasPrefix("/Volumes/") {
            let parts = dest.split(separator: "/", maxSplits: 3)
            if parts.count >= 2 {
                let volRoot = "/Volumes/\(parts[1])"
                return FileManager.default.fileExists(atPath: volRoot)
            }
        }
        return FileManager.default.fileExists(atPath: dest)
    }

    private let statusFilePath: String = {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return "\(home)/.local/share/rusty-mac-backup/status.json"
    }()

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        readScheduleState()
        reloadConfig()
        wasDiskConnected = isDiskConnected  // Initialize before first poll
        pollStatus()
        schedulePollTimer(interval: 30)
        requestNotificationPermission()

        // Check for updates on launch (after 5s delay to not block startup)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            AutoUpdater.shared.checkForUpdates { [weak self] hasUpdate in
                if hasUpdate { self?.buildMenu() }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollTimer?.invalidate()
        animationTimer?.invalidate()
    }

    // MARK: Status Bar Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIdleIcon(stale: false, hasError: false)
        buildMenu()
    }

    // MARK: Icon Management

    private func loadBundleIcon(_ name: String) -> NSImage? {
        // Try loading PNG from app bundle Resources
        if let path = Bundle.main.path(forResource: name, ofType: "png") {
            if let img = NSImage(contentsOfFile: path) {
                img.isTemplate = true
                img.size = NSSize(width: 18, height: 18)
                return img
            }
        }
        return nil
    }

    private func setIdleIcon(stale: Bool, hasError: Bool) {
        stopAnimation()
        guard let button = statusItem.button else { return }

        let symbolName: String
        if !isDiskConnected {
            symbolName = "externaldrive.trianglebadge.exclamationmark"
        } else if hasError {
            symbolName = "gauge.open.with.lines.needle.84percent.exclamation"
        } else if stale {
            symbolName = "gauge.with.dots.needle.bottom.0percent"
        } else {
            symbolName = "externaldrive.fill.badge.checkmark"
        }

        if let img = NSImage(systemSymbolName: symbolName,
                              accessibilityDescription: "RustyMacBackup") {
            img.isTemplate = true
            button.image = img
            button.title = ""
        } else {
            button.image = nil
            button.title = "RMB"
        }
    }

    private func startAnimation() {
        guard animationTimer == nil else { return }
        animationFrame = 0

        // Ferrari tachometer animation: needle sweeping up as backup progresses
        let gaugeFrames = [
            "gauge.with.dots.needle.bottom.0percent",
            "gauge.with.dots.needle.33percent",
            "gauge.with.dots.needle.bottom.50percent",
            "gauge.with.dots.needle.67percent",
        ]
        let images = gaugeFrames.compactMap { name -> NSImage? in
            let img = NSImage(systemSymbolName: name, accessibilityDescription: "Backing up")
            img?.isTemplate = true
            return img
        }

        guard !images.isEmpty else { return }

        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            guard let self = self, let button = self.statusItem.button else { return }
            self.animationFrame = (self.animationFrame + 1) % images.count
            button.image = images[self.animationFrame]
            button.title = ""
        }
        if let button = statusItem.button {
            button.image = images[0]
            button.title = ""
        }
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    // MARK: Polling

    private func schedulePollTimer(interval: TimeInterval) {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.pollStatus()
        }
    }

    private func pollStatus() {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: statusFilePath))
        } catch {
            // No status file yet — treat as idle with no data
            if currentStatus != nil || previousState != "idle" {
                currentStatus = nil
                previousState = "idle"
                DispatchQueue.main.async { [weak self] in
                    self?.setIdleIcon(stale: true, hasError: false)
                    self?.buildMenu()
                }
            }
            return
        }

        let decoder = JSONDecoder()
        guard let status = try? decoder.decode(BackupStatus.self, from: data) else { return }

        let oldState = previousState
        currentStatus = status
        previousState = status.state

        // Detect disk reconnection
        let diskNow = isDiskConnected
        let diskJustReconnected = diskNow && !wasDiskConnected
        wasDiskConnected = diskNow

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Auto-resume backup if disk reconnected and last backup was interrupted
            if diskJustReconnected && status.state != "running" {
                if status.state == "error" || self.isBackupStale(status) {
                    self.sendNotification(title: "Disco ricollegato",
                                          body: "Riavvio backup automatico...")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        self.backupNow()
                    }
                }
            }

            switch status.state {
            case "running":
                self.startAnimation()
                if oldState != "running" {
                    self.schedulePollTimer(interval: 2)
                }

            case "error":
                self.setIdleIcon(stale: false, hasError: true)
                if oldState == "running" {
                    self.schedulePollTimer(interval: 30)
                    self.sendNotification(title: "Backup Error",
                                          body: "Backup encountered \(status.errors ?? 0) error(s).")
                }

            default: // idle
                let stale = self.isBackupStale(status)
                self.setIdleIcon(stale: stale, hasError: false)
                if oldState == "running" {
                    self.schedulePollTimer(interval: 30)
                    let dur = status.last_duration_secs.map { Fmt.duration($0) } ?? "?"
                    let files = status.files_total.map { Fmt.number($0) } ?? "?"
                    self.sendNotification(title: "Backup Complete",
                                          body: "Duration: \(dur) | \(files) files")
                }
            }

            self.buildMenu()
        }
    }

    private func isBackupStale(_ status: BackupStatus) -> Bool {
        guard let lastStr = status.last_completed,
              let lastDate = Fmt.parseISO(lastStr) else { return true }
        return -lastDate.timeIntervalSinceNow > 86400 // > 24 hours
    }

    private func isBackupRecent(_ status: BackupStatus) -> Bool {
        guard let lastStr = status.last_completed,
              let lastDate = Fmt.parseISO(lastStr) else { return false }
        return -lastDate.timeIntervalSinceNow < 7200 // < 2 hours
    }

    // MARK: Menu Building

    private func buildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // Check if setup is needed
        let configExists = FileManager.default.fileExists(atPath: ConfigManager.configPath)
        let hasFullDiskAccess = checkFullDiskAccess()

        if !configExists {
            // No config -- show setup required
            let header = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            header.attributedTitle = MLText.build(
                MLText.dot(MLColor.rosso),
                MLText.colored("Setup Required", MLColor.rosso)
            )
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(NSMenuItem.separator())

            let setupItem = NSMenuItem(title: "Run First-Time Setup...", action: #selector(runSetup), keyEquivalent: "")
            setupItem.target = self
            menu.addItem(setupItem)

            let helpItem = NSMenuItem(title: "Open in terminal: rustyback init", action: nil, keyEquivalent: "")
            helpItem.isEnabled = false
            menu.addItem(helpItem)

            menu.addItem(NSMenuItem.separator())
            let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
            quitItem.target = self
            menu.addItem(quitItem)
            statusItem.menu = menu
            return
        }

        if !hasFullDiskAccess {
            // Config exists but no FDA
            let header = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            header.attributedTitle = MLText.header("RustyMacBackup")
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(NSMenuItem.separator())

            let fdaItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            fdaItem.attributedTitle = MLText.build(
                MLText.dot(MLColor.rosso),
                MLText.colored("Full Disk Access Required", MLColor.rosso)
            )
            fdaItem.isEnabled = false
            menu.addItem(fdaItem)

            let fixItem = NSMenuItem(title: "Open Privacy Settings...", action: #selector(openFDASettings), keyEquivalent: "")
            fixItem.target = self
            menu.addItem(fixItem)

            let helpItem = NSMenuItem(title: "Add RustyBackMenu.app to Full Disk Access", action: nil, keyEquivalent: "")
            helpItem.isEnabled = false
            menu.addItem(helpItem)

            menu.addItem(NSMenuItem.separator())
            let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
            quitItem.target = self
            menu.addItem(quitItem)
            statusItem.menu = menu
            return
        }

        // Normal menu -- config exists and FDA granted
        // Header with Maranello styling
        let header = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        if currentStatus?.state == "running" {
            header.attributedTitle = MLText.build(
                MLText.colored("RustyMacBackup", MLColor.gold),
                MLText.small("  LIVE", MLColor.verde)
            )
        } else {
            header.attributedTitle = MLText.header("RustyMacBackup")
        }
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        if let status = currentStatus, status.state == "running" {
            addRunningSection(to: menu, status: status)
        } else if !isDiskConnected {
            addDiskAbsentSection(to: menu)
        } else {
            addIdleSection(to: menu)
        }

        menu.addItem(NSMenuItem.separator())

        // Actions
        let backupNowItem = NSMenuItem(title: "Backup Now", action: #selector(backupNow), keyEquivalent: "b")
        backupNowItem.keyEquivalentModifierMask = .command
        backupNowItem.target = self
        if currentStatus?.state == "running" {
            backupNowItem.attributedTitle = MLText.build(
                MLText.dot(MLColor.gold),
                MLText.colored("Backup in corso", MLColor.gold),
                MLText.small("  stop: \u{2318}B", MLColor.grigio)
            )
            backupNowItem.action = #selector(stopBackup)
        } else if !isDiskConnected {
            backupNowItem.attributedTitle = MLText.build(
                MLText.dot(MLColor.rosso),
                MLText.small("Backup Now — disco assente", MLColor.rosso)
            )
            backupNowItem.isEnabled = false
        } else {
            backupNowItem.attributedTitle = MLText.build(
                MLText.dot(MLColor.verde),
                MLText.colored("Backup Now", MLColor.verde)
            )
        }
        menu.addItem(backupNowItem)

        // Open Backup Folder — disabled without disk
        let openItem = NSMenuItem(title: "Open Backup Folder", action: #selector(openBackupFolder), keyEquivalent: "o")
        openItem.keyEquivalentModifierMask = .command
        openItem.target = self
        if !isDiskConnected {
            openItem.isEnabled = false
        }
        menu.addItem(openItem)

        menu.addItem(NSMenuItem.separator())

        // Schedule submenu — always available (it's a preference)
        addScheduleSubmenu(to: menu)

        menu.addItem(NSMenuItem.separator())

        // Preferences submenu — always available
        addPreferencesSubmenu(to: menu)

        menu.addItem(NSMenuItem.separator())

        let logItem = NSMenuItem(title: "View Backup Log", action: #selector(viewLog), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)

        // Update available
        if AutoUpdater.shared.updateAvailable {
            menu.addItem(NSMenuItem.separator())
            let updateItem = NSMenuItem(title: "", action: #selector(installUpdate), keyEquivalent: "u")
            updateItem.keyEquivalentModifierMask = .command
            updateItem.target = self
            updateItem.attributedTitle = MLText.build(
                MLText.dot(MLColor.verde),
                MLText.colored("Aggiornamento v\(AutoUpdater.shared.updateVersionString)", MLColor.verde)
            )
            menu.addItem(updateItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = .command
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func addDiskAbsentSection(to menu: NSMenu) {
        // Disk name from config
        let dest = cachedConfig.destPath
        var diskName = "disco esterno"
        if dest.hasPrefix("/Volumes/") {
            let parts = dest.split(separator: "/", maxSplits: 3)
            if parts.count >= 2 { diskName = String(parts[1]) }
        }

        // Same structure as idle section but with disk error
        // Last backup info
        if let status = currentStatus,
           let lastStr = status.last_completed,
           let lastDate = Fmt.parseISO(lastStr) {
            let elapsed = -lastDate.timeIntervalSinceNow
            let timeStr = Fmt.relativeTime(from: lastDate)
            let timeColor: NSColor = elapsed < 86400 ? MLColor.verde
                : elapsed < 172800 ? MLColor.gold : MLColor.rosso

            let lastItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            lastItem.attributedTitle = MLText.build(
                MLText.dot(timeColor),
                MLText.plain("Ultimo backup: "),
                MLText.colored(timeStr, timeColor)
            )
            lastItem.isEnabled = false
            menu.addItem(lastItem)

            // Duration + files
            if let dur = status.last_duration_secs, let files = status.files_total {
                let copiedStr = status.bytes_copied.map { Fmt.bytes($0) } ?? ""
                let durItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                durItem.attributedTitle = MLText.build(
                    MLText.small("  "),
                    MLText.small(Fmt.duration(dur), MLColor.gold),
                    MLText.small("  ·  ", MLColor.grigio),
                    MLText.small("\(Fmt.number(files)) file", MLColor.grigio),
                    copiedStr.isEmpty ? MLText.plain("") : MLText.small("  ·  \(copiedStr)", MLColor.grigio)
                )
                durItem.isEnabled = false
                menu.addItem(durItem)
            }
        }

        // Disk status — ROSSO: it's a problem, not a warning
        let diskItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        diskItem.attributedTitle = MLText.build(
            MLText.dot(MLColor.rosso),
            MLText.colored("Disco \"\(diskName)\" non collegato", MLColor.rosso)
        )
        diskItem.isEnabled = false
        menu.addItem(diskItem)
    }

    private func addIdleSection(to menu: NSMenu) {
        // Last backup with color-coded time
        if let status = currentStatus,
           let lastStr = status.last_completed,
           let lastDate = Fmt.parseISO(lastStr) {
            let elapsed = -lastDate.timeIntervalSinceNow
            let timeStr = Fmt.relativeTime(from: lastDate)
            let timeColor: NSColor
            if elapsed < 86400 {       // <24h verde
                timeColor = MLColor.verde
            } else if elapsed < 172800 { // <48h gold
                timeColor = MLColor.gold
            } else {                     // >48h rosso
                timeColor = MLColor.rosso
            }
            let lastItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            lastItem.attributedTitle = MLText.build(
                MLText.dot(timeColor),
                MLText.plain("Ultimo backup: "),
                MLText.colored(timeStr, timeColor)
            )
            lastItem.isEnabled = false
            menu.addItem(lastItem)
        } else {
            let lastItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            lastItem.attributedTitle = MLText.build(
                MLText.dot(MLColor.rosso),
                MLText.plain("Ultimo backup: "),
                MLText.colored("mai", MLColor.rosso)
            )
            lastItem.isEnabled = false
            menu.addItem(lastItem)
        }

        // Duration + files + bytes on one line
        if let status = currentStatus,
           let dur = status.last_duration_secs,
           let files = status.files_total {
            let durItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            let copiedStr = status.bytes_copied.map { Fmt.bytes($0) } ?? ""
            durItem.attributedTitle = MLText.build(
                MLText.small("  "),
                MLText.small(Fmt.duration(dur), MLColor.gold),
                MLText.small("  ·  ", MLColor.grigio),
                MLText.small("\(Fmt.number(files)) file", MLColor.grigio),
                copiedStr.isEmpty ? MLText.plain("") : MLText.small("  ·  \(copiedStr)", MLColor.grigio)
            )
            durItem.isEnabled = false
            menu.addItem(durItem)
        }

        // Disk info with semantic health colors
        refreshDiskDetailIfStale()
        if let detail = cachedDiskDetail {
            let diskItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            // Parse free space for color coding
            let freeColor: NSColor
            let fs = detail.freeSpace.lowercased()
            if fs.contains("tb") || (fs.contains("gb") && Double(fs.replacingOccurrences(of: "[^0-9.,]", with: "", options: .regularExpression).replacingOccurrences(of: ",", with: ".")) ?? 0 > 50) {
                freeColor = MLColor.verde     // >50GB = healthy
            } else if fs.contains("gb") {
                freeColor = MLColor.warning   // <50GB = warning
            } else {
                freeColor = MLColor.rosso     // MB = critical
            }
            diskItem.attributedTitle = MLText.build(
                MLText.small("  ", MLColor.grigio),
                MLText.small(detail.volumeName, MLColor.info),
                MLText.small("  \(detail.freeSpace) liberi", freeColor)
            )
            diskItem.isEnabled = false
            menu.addItem(diskItem)
        }

        // Next scheduled backup
        if scheduleEnabled, let status = currentStatus,
           let lastStr = status.last_completed,
           let _ = Fmt.parseISO(lastStr) {
            let nextStr = Fmt.timeUntil(minutes: scheduleIntervalMinutes,
                                        lastCompleted: Fmt.parseISO(lastStr))
            let nextItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            nextItem.attributedTitle = MLText.build(
                MLText.small("  Prossimo: ", MLColor.grigio),
                MLText.small(nextStr, MLColor.gold)
            )
            nextItem.isEnabled = false
            menu.addItem(nextItem)
        }

        // Skipped files (warning, not error — SIP-protected system files)
        if let status = currentStatus, let errs = status.errors, errs > 0 {
            let errItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            errItem.attributedTitle = MLText.build(
                MLText.small("  \(errs) file di sistema ignorati", MLColor.warning),
                MLText.small(" (normale)", MLColor.grigio)
            )
            errItem.isEnabled = false
            menu.addItem(errItem)
        }
    }

    private func addRunningSection(to menu: NSMenu, status: BackupStatus) {
        let done = status.files_done ?? 0
        let total = status.files_total ?? 1
        let pct = total > 0 ? Int(Double(done) / Double(total) * 100) : 0

        // Gradient progress bar (rosso → gold → verde)
        let progressBar = ProgressBarView(frame: NSRect(x: 0, y: 0, width: 250, height: 32))
        progressBar.percent = Double(pct)
        let progressItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        progressItem.view = progressBar
        menu.addItem(progressItem)

        // Bytes copied (accent) + file count (muted)
        let copiedBytes = status.bytes_copied ?? 0
        let copiedStr = Fmt.bytes(copiedBytes)
        let filesItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        filesItem.attributedTitle = MLText.build(
            MLText.colored("  \(copiedStr)", MLColor.gold),
            MLText.plain(" copiati  "),
            MLText.small("\(Fmt.number(done)) / \(Fmt.number(total)) file", MLColor.grigio)
        )
        filesItem.isEnabled = false
        menu.addItem(filesItem)

        // Ferrari speedometer gauge
        let speedView = SpeedometerView(frame: NSRect(x: 0, y: 0, width: 220, height: 90))
        if let bps = status.bytes_per_sec, bps > 0 {
            speedView.speedMBps = Double(bps) / (1024 * 1024)
        }
        if let eta = status.eta_secs, eta > 0 {
            speedView.etaText = Fmt.duration(Double(eta))
        }
        let speedItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        speedItem.view = speedView
        menu.addItem(speedItem)

        // Current file — cleaned up
        if let file = status.current_file, !file.isEmpty {
            let clean = MLText.cleanPath(file)
            let fileItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            fileItem.attributedTitle = MLText.small("  \(clean)", MLColor.grigio)
            fileItem.isEnabled = false
            menu.addItem(fileItem)
        }

        // Skipped files: warning (not error!) — these are normal SIP-protected files
        if let errs = status.errors, errs > 0 {
            let errItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            errItem.attributedTitle = MLText.build(
                MLText.small("  ", MLColor.warning),
                MLText.small("\(errs) file protetti ignorati", MLColor.warning),
                MLText.small(" (normale)", MLColor.grigio)
            )
            errItem.isEnabled = false
            menu.addItem(errItem)
        }
    }

    private func addScheduleSubmenu(to menu: NSMenu) {
        let schedLabel = scheduleEnabled
            ? (scheduleIntervalMinutes >= 1440
                ? "Schedule: Daily at \(scheduleIntervalMinutes / 60 - 24 + (scheduleIntervalMinutes % 60 == 0 ? 0 : 1)):00"
                : "Schedule: Every \(scheduleIntervalMinutes) min")
            : "Schedule: Disabled"
        let schedItem = NSMenuItem(title: schedLabel, action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        for mins in [15, 30, 60, 120] {
            let label = mins < 60 ? "Every \(mins) min" : "Every \(mins / 60) hour\(mins > 60 ? "s" : "")"
            let item = NSMenuItem(title: label, action: #selector(changeInterval(_:)), keyEquivalent: "")
            item.tag = mins
            item.target = self
            if mins == scheduleIntervalMinutes && scheduleEnabled {
                item.state = .on
            }
            submenu.addItem(item)
        }

        submenu.addItem(NSMenuItem.separator())

        // Daily schedule options
        let dailyHeader = NSMenuItem(title: "Daily at:", action: nil, keyEquivalent: "")
        dailyHeader.isEnabled = false
        submenu.addItem(dailyHeader)
        for hour in [2, 3, 4, 6] {
            let label = String(format: "%02d:00 AM", hour)
            let item = NSMenuItem(title: label, action: #selector(changeDailySchedule(_:)), keyEquivalent: "")
            item.tag = hour
            item.target = self
            submenu.addItem(item)
        }

        submenu.addItem(NSMenuItem.separator())

        if scheduleEnabled {
            let disableItem = NSMenuItem(title: "Disable", action: #selector(disableSchedule), keyEquivalent: "")
            disableItem.target = self
            submenu.addItem(disableItem)
        } else {
            let enableItem = NSMenuItem(title: "Enable", action: #selector(enableSchedule), keyEquivalent: "")
            enableItem.target = self
            submenu.addItem(enableItem)
        }

        schedItem.submenu = submenu
        menu.addItem(schedItem)
    }

    // MARK: Preferences Submenu

    private func addPreferencesSubmenu(to menu: NSMenu) {
        let prefsItem = NSMenuItem(title: "Preferences", action: nil, keyEquivalent: ",")
        prefsItem.keyEquivalentModifierMask = .command
        let prefsMenu = NSMenu()

        // Backup Disk >
        let diskItem = NSMenuItem(title: "Backup Disk", action: nil, keyEquivalent: "")
        diskItem.submenu = buildBackupDiskSubmenu()
        prefsMenu.addItem(diskItem)

        // Source Paths >
        let sourcesItem = NSMenuItem(title: "Source Paths", action: nil, keyEquivalent: "")
        sourcesItem.submenu = buildSourcePathsSubmenu()
        prefsMenu.addItem(sourcesItem)

        // Excludes >
        let excludesItem = NSMenuItem(title: "Excludes", action: nil, keyEquivalent: "")
        excludesItem.submenu = buildExcludesSubmenu()
        prefsMenu.addItem(excludesItem)

        // Retention >
        let retentionItem = NSMenuItem(title: "Retention", action: nil, keyEquivalent: "")
        retentionItem.submenu = buildRetentionSubmenu()
        prefsMenu.addItem(retentionItem)

        prefsItem.submenu = prefsMenu
        menu.addItem(prefsItem)
    }

    private func buildBackupDiskSubmenu() -> NSMenu {
        let sub = NSMenu()
        let volumes = VolumeScanner.connectedVolumes()
        let currentDest = cachedConfig.destPath

        if volumes.isEmpty {
            let noDisks = NSMenuItem(title: "No external disks found", action: nil, keyEquivalent: "")
            noDisks.isEnabled = false
            sub.addItem(noDisks)
        } else {
            for vol in volumes {
                let item = NSMenuItem(title: "", action: #selector(selectBackupDisk(_:)), keyEquivalent: "")
                let encColor = vol.isEncrypted ? MLColor.verde : MLColor.rosso
                let encLabel = vol.isEncrypted ? "Encrypted" : "Not encrypted"
                item.attributedTitle = MLText.build(
                    MLText.bold(vol.name),
                    MLText.plain(" -- \(vol.freeSpaceFormatted) "),
                    MLText.colored(encLabel, encColor)
                )
                item.target = self
                item.representedObject = vol.path as NSString
                if currentDest.hasPrefix(vol.path) {
                    item.state = .on
                }
                sub.addItem(item)
            }
        }

        return sub
    }

    private func buildSourcePathsSubmenu() -> NSMenu {
        let sub = NSMenu()
        let paths = cachedConfig.allSourcePaths

        // Show current paths as disabled info items
        for path in paths {
            let item = NSMenuItem(title: path, action: nil, keyEquivalent: "")
            item.isEnabled = false
            sub.addItem(item)
        }

        sub.addItem(NSMenuItem.separator())

        // Add Path...
        let addItem = NSMenuItem(title: "Add Path…", action: #selector(addSourcePath), keyEquivalent: "")
        addItem.target = self
        sub.addItem(addItem)

        // Remove Path >
        if !cachedConfig.extraPaths.isEmpty {
            let removeItem = NSMenuItem(title: "Remove Path", action: nil, keyEquivalent: "")
            let removeSub = NSMenu()
            for path in cachedConfig.extraPaths {
                let item = NSMenuItem(title: path, action: #selector(removeSourcePath(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = path as NSString
                removeSub.addItem(item)
            }
            removeItem.submenu = removeSub
            sub.addItem(removeItem)
        }

        return sub
    }

    private func buildExcludesSubmenu() -> NSMenu {
        let sub = NSMenu()
        let patterns = cachedConfig.excludePatterns

        // Count
        let countItem = NSMenuItem(title: "\(patterns.count) patterns active", action: nil, keyEquivalent: "")
        countItem.isEnabled = false
        sub.addItem(countItem)

        sub.addItem(NSMenuItem.separator())

        // Add Exclude...
        let addItem = NSMenuItem(title: "Add Exclude…", action: #selector(addExcludePattern), keyEquivalent: "")
        addItem.target = self
        sub.addItem(addItem)

        // Remove Exclude >
        if !patterns.isEmpty {
            let removeItem = NSMenuItem(title: "Remove Exclude", action: nil, keyEquivalent: "")
            let removeSub = NSMenu()
            for pattern in patterns {
                let item = NSMenuItem(title: pattern, action: #selector(removeExcludePattern(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = pattern as NSString
                removeSub.addItem(item)
            }
            removeItem.submenu = removeSub
            sub.addItem(removeItem)
        }

        sub.addItem(NSMenuItem.separator())

        // Common Excludes >
        let commonItem = NSMenuItem(title: "Common Excludes", action: nil, keyEquivalent: "")
        commonItem.submenu = buildCommonExcludesSubmenu()
        sub.addItem(commonItem)

        return sub
    }

    private func buildCommonExcludesSubmenu() -> NSMenu {
        let sub = NSMenu()
        let current = Set(cachedConfig.excludePatterns)
        let presets: [(String, Bool)] = [
            ("node_modules", true),
            (".git/objects", true),
            ("OneDrive*", true),
            ("Library/Caches", true),
            ("Downloads", false),
            ("Movies", false),
            (".ollama/models", false),
        ]

        for (pattern, _) in presets {
            let isActive = current.contains(pattern)
            let item = NSMenuItem(title: pattern, action: #selector(toggleCommonExclude(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = pattern as NSString
            item.state = isActive ? .on : .off
            sub.addItem(item)
        }

        return sub
    }

    private func buildRetentionSubmenu() -> NSMenu {
        let sub = NSMenu()
        let cfg = cachedConfig

        let hourlyLabel = "Hourly: \(cfg.hourly)"
        let hourlyItem = NSMenuItem(title: hourlyLabel, action: nil, keyEquivalent: "")
        let hourlySub = NSMenu()
        for val in [6, 12, 24, 48] {
            let item = NSMenuItem(title: "\(val)", action: #selector(changeRetentionHourly(_:)), keyEquivalent: "")
            item.tag = val
            item.target = self
            if val == cfg.hourly { item.state = .on }
            hourlySub.addItem(item)
        }
        hourlyItem.submenu = hourlySub
        sub.addItem(hourlyItem)

        let dailyLabel = "Daily: \(cfg.daily)"
        let dailyItem = NSMenuItem(title: dailyLabel, action: nil, keyEquivalent: "")
        let dailySub = NSMenu()
        for val in [7, 14, 30, 60] {
            let item = NSMenuItem(title: "\(val)", action: #selector(changeRetentionDaily(_:)), keyEquivalent: "")
            item.tag = val
            item.target = self
            if val == cfg.daily { item.state = .on }
            dailySub.addItem(item)
        }
        dailyItem.submenu = dailySub
        sub.addItem(dailyItem)

        let weeklyLabel = "Weekly: \(cfg.weekly)"
        let weeklyItem = NSMenuItem(title: weeklyLabel, action: nil, keyEquivalent: "")
        let weeklySub = NSMenu()
        for val in [12, 26, 52, 104] {
            let item = NSMenuItem(title: "\(val)", action: #selector(changeRetentionWeekly(_:)), keyEquivalent: "")
            item.tag = val
            item.target = self
            if val == cfg.weekly { item.state = .on }
            weeklySub.addItem(item)
        }
        weeklyItem.submenu = weeklySub
        sub.addItem(weeklyItem)

        let monthlyDisplay = cfg.monthly == 0 ? "forever" : "\(cfg.monthly)"
        let monthlyLabel = "Monthly: \(monthlyDisplay)"
        let monthlyItem = NSMenuItem(title: monthlyLabel, action: nil, keyEquivalent: "")
        let monthlySub = NSMenu()
        for val in [6, 12, 0] {
            let label = val == 0 ? "forever" : "\(val)"
            let item = NSMenuItem(title: label, action: #selector(changeRetentionMonthly(_:)), keyEquivalent: "")
            item.tag = val
            item.target = self
            if val == cfg.monthly { item.state = .on }
            monthlySub.addItem(item)
        }
        monthlyItem.submenu = monthlySub
        sub.addItem(monthlyItem)

        return sub
    }

    // MARK: Config & Disk Caching

    private func reloadConfig() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let config = ConfigManager.load()
            let detail = DiskInfo.detail(for: config)
            DispatchQueue.main.async {
                self?.cachedConfig = config
                self?.cachedDiskDetail = detail
                self?.diskDetailLastChecked = Date()
                self?.buildMenu()
            }
        }
    }

    private func refreshDiskDetailIfStale() {
        if -diskDetailLastChecked.timeIntervalSinceNow > 300 {
            refreshDiskDetail()
        }
    }

    private func refreshDiskDetail() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let detail = DiskInfo.detail(for: self?.cachedConfig ?? ConfigManager.load())
            DispatchQueue.main.async {
                self?.cachedDiskDetail = detail
                self?.diskDetailLastChecked = Date()
            }
        }
    }

    // MARK: Schedule State

    private func readScheduleState() {
        Shell.runAsync("rustyback schedule status 2>/dev/null") { [weak self] output in
            guard let self = self else { return }
            let lower = output.lowercased()
            self.scheduleEnabled = lower.contains("active") || lower.contains("enabled")

            // Try to parse interval from output (e.g. "every 60 min")
            let pattern = try? NSRegularExpression(pattern: "(\\d+)\\s*min", options: .caseInsensitive)
            if let match = pattern?.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
               let range = Range(match.range(at: 1), in: output),
               let mins = Int(output[range]) {
                self.scheduleIntervalMinutes = mins
            }
            self.buildMenu()
        }
    }

    // MARK: Actions

    @objc private func backupNow() {
        guard currentStatus?.state != "running" else {
            stopBackup()
            return
        }

        // Clear old error log before starting
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let errorLogPath = "\(home)/.local/share/rusty-mac-backup/backup-error.log"
        try? "".write(toFile: errorLogPath, atomically: true, encoding: .utf8)

        // Immediately show backing-up state in menu
        startAnimation()
        buildMenu()

        // Switch to fast polling
        schedulePollTimer(interval: 2)

        Shell.runAsync("rustyback backup 2>&1") { [weak self] result in
            guard let self = self else { return }
            self.pollStatus()

            // Check for errors in the output
            let lower = result.lowercased()
            if lower.contains("error") || lower.contains("failed") || lower.contains("bail") {
                // Log the error
                try? result.write(toFile: errorLogPath, atomically: true, encoding: .utf8)

                self.sendNotification(
                    title: "Backup Failed",
                    body: String(result.prefix(200))
                )
            }
        }
    }

    @objc private func stopBackup() {
        Shell.runAsync("rustyback stop 2>&1") { [weak self] _ in
            self?.pollStatus()
        }
    }

    @objc private func openBackupFolder() {
        Shell.runAsync("rustyback config show 2>/dev/null") { output in
            let components = output.components(separatedBy: "\"")
            for c in components {
                if c.hasPrefix("/Volumes/") || c.hasPrefix("/") && c.contains("Backup") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: c))
                    return
                }
            }
            // Fallback: open home
            NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()))
        }
    }

    @objc private func changeInterval(_ sender: NSMenuItem) {
        let mins = sender.tag
        scheduleIntervalMinutes = mins
        scheduleEnabled = true
        Shell.runAsync("rustyback schedule interval \(mins) 2>&1") { [weak self] _ in
            self?.readScheduleState()
        }
        buildMenu()
    }

    @objc private func changeDailySchedule(_ sender: NSMenuItem) {
        let hour = sender.tag
        scheduleEnabled = true
        scheduleIntervalMinutes = 1440 // mark as daily
        Shell.runAsync("rustyback schedule daily \(hour) 2>&1") { [weak self] _ in
            self?.readScheduleState()
        }
        buildMenu()
    }

    @objc private func disableSchedule() {
        scheduleEnabled = false
        Shell.runAsync("rustyback schedule off 2>&1") { [weak self] _ in
            self?.readScheduleState()
        }
        buildMenu()
    }

    @objc private func enableSchedule() {
        scheduleEnabled = true
        Shell.runAsync("rustyback schedule on 2>&1") { [weak self] _ in
            self?.readScheduleState()
        }
        buildMenu()
    }

    @objc private func selectBackupDisk(_ sender: NSMenuItem) {
        guard let volumePath = sender.representedObject as? String else { return }
        let destPath = "\(volumePath)/RustyMacBackup"

        // Check encryption
        let vol = VolumeScanner.connectedVolumes().first { $0.path == volumePath }
        if let v = vol, !v.isEncrypted {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Disk Not Encrypted"
                alert.informativeText = """
                \(v.name) is not encrypted. Your backups will be stored unencrypted.

                To encrypt: open Disk Utility → select \(v.name) → File → Encrypt "\(v.name)…"

                Or use Finder: right-click the disk → Encrypt "\(v.name)…"
                """
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Use Anyway")
                alert.addButton(withTitle: "Cancel")
                NSApp.activate(ignoringOtherApps: true)
                let response = alert.runModal()
                if response != .alertFirstButtonReturn { return }

                Shell.runAsync("rustyback config dest \"\(destPath)\" 2>&1") { [weak self] _ in
                    self?.reloadConfig()
                }
            }
            return
        }

        Shell.runAsync("rustyback config dest \"\(destPath)\" 2>&1") { [weak self] _ in
            self?.reloadConfig()
        }
    }

    @objc private func addSourcePath() {
        DispatchQueue.main.async { [weak self] in
            let panel = NSOpenPanel()
            panel.title = "Select Source Directory"
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = false
            NSApp.activate(ignoringOtherApps: true)

            if panel.runModal() == .OK, let url = panel.url {
                let path = url.path
                DispatchQueue.global(qos: .userInitiated).async {
                    ConfigManager.addExtraPath(path)
                    DispatchQueue.main.async {
                        self?.reloadConfig()
                    }
                }
            }
        }
    }

    @objc private func removeSourcePath(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            ConfigManager.removeExtraPath(path)
            DispatchQueue.main.async {
                self?.reloadConfig()
            }
        }
    }

    @objc private func addExcludePattern() {
        DispatchQueue.main.async { [weak self] in
            let alert = NSAlert()
            alert.messageText = "Add Exclude Pattern"
            alert.informativeText = "Enter a glob pattern to exclude from backups.\nExamples: *.log, Downloads, .cache"
            alert.addButton(withTitle: "Add")
            alert.addButton(withTitle: "Cancel")

            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            input.placeholderString = "pattern (e.g. *.log)"
            alert.accessoryView = input
            alert.window.initialFirstResponder = input
            NSApp.activate(ignoringOtherApps: true)

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                let pattern = input.stringValue.trimmingCharacters(in: .whitespaces)
                guard !pattern.isEmpty else { return }
                Shell.runAsync("rustyback config exclude \"\(pattern)\" 2>&1") { _ in
                    self?.reloadConfig()
                }
            }
        }
    }

    @objc private func removeExcludePattern(_ sender: NSMenuItem) {
        guard let pattern = sender.representedObject as? String else { return }
        Shell.runAsync("rustyback config include \"\(pattern)\" 2>&1") { [weak self] _ in
            self?.reloadConfig()
        }
    }

    @objc private func toggleCommonExclude(_ sender: NSMenuItem) {
        guard let pattern = sender.representedObject as? String else { return }
        let isCurrentlyActive = cachedConfig.excludePatterns.contains(pattern)
        if isCurrentlyActive {
            Shell.runAsync("rustyback config include \"\(pattern)\" 2>&1") { [weak self] _ in
                self?.reloadConfig()
            }
        } else {
            Shell.runAsync("rustyback config exclude \"\(pattern)\" 2>&1") { [weak self] _ in
                self?.reloadConfig()
            }
        }
    }

    @objc private func changeRetentionHourly(_ sender: NSMenuItem) {
        Shell.runAsync("rustyback config retention --hourly \(sender.tag) 2>&1") { [weak self] _ in
            self?.reloadConfig()
        }
    }

    @objc private func changeRetentionDaily(_ sender: NSMenuItem) {
        Shell.runAsync("rustyback config retention --daily \(sender.tag) 2>&1") { [weak self] _ in
            self?.reloadConfig()
        }
    }

    @objc private func changeRetentionWeekly(_ sender: NSMenuItem) {
        Shell.runAsync("rustyback config retention --weekly \(sender.tag) 2>&1") { [weak self] _ in
            self?.reloadConfig()
        }
    }

    @objc private func changeRetentionMonthly(_ sender: NSMenuItem) {
        Shell.runAsync("rustyback config retention --monthly \(sender.tag) 2>&1") { [weak self] _ in
            self?.reloadConfig()
        }
    }

    @objc private func viewLog() {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let logPath = "\(home)/.local/share/rusty-mac-backup/backup.log"
        if FileManager.default.fileExists(atPath: logPath) {
            NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
        } else {
            // Try to find log via CLI
            Shell.runAsync("rustyback log path 2>/dev/null") { output in
                let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty && FileManager.default.fileExists(atPath: path) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                } else {
                    DispatchQueue.main.async {
                        let alert = NSAlert()
                        alert.messageText = "No Log Found"
                        alert.informativeText = "No backup log file was found."
                        alert.alertStyle = .informational
                        alert.addButton(withTitle: "OK")
                        alert.runModal()
                    }
                }
            }
        }
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func installUpdate() {
        AutoUpdater.shared.downloadUpdate()
    }

    @objc private func runSetup() {
        // Open terminal and run rustyback init
        let script = "tell application \"Terminal\" to do script \"rustyback init\""
        NSAppleScript(source: script)?.executeAndReturnError(nil)
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
    }

    @objc private func openFDASettings() {
        // Open System Settings > Privacy > Full Disk Access
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    private func checkFullDiskAccess() -> Bool {
        // FDA is managed by the user via System Settings
        // We can't reliably detect it programmatically on all macOS versions
        // If backup fails due to permissions, the error will be shown in status
        return true
    }

    // MARK: Notifications

    private func requestNotificationPermission() {
        if #available(macOS 10.14, *) {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    private func sendNotification(title: String, body: String) {
        if #available(macOS 10.14, *) {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }
}

// MARK: - Auto-Updater

class AutoUpdater {
    static let shared = AutoUpdater()
    private let repo = "Roberdan/RustyMacBackup"
    private let currentVersion: String = {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }()
    private var latestVersion: String?
    private var downloadURL: String?
    private var lastCheck: Date = .distantPast

    func checkForUpdates(force: Bool = false, completion: ((Bool) -> Void)? = nil) {
        // Check at most once per hour (unless forced)
        if !force && -lastCheck.timeIntervalSinceNow < 3600 {
            completion?(latestVersion != nil && latestVersion != currentVersion)
            return
        }

        let urlStr = "https://api.github.com/repos/\(repo)/releases/latest"
        guard let url = URL(string: urlStr) else {
            completion?(false)
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self = self, let data = data, error == nil else {
                DispatchQueue.main.async { completion?(false) }
                return
            }

            self.lastCheck = Date()

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String else {
                DispatchQueue.main.async { completion?(false) }
                return
            }

            let remoteVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
            self.latestVersion = remoteVersion

            // Find .pkg asset
            if let assets = json["assets"] as? [[String: Any]] {
                for asset in assets {
                    if let name = asset["name"] as? String, name.hasSuffix(".pkg"),
                       let url = asset["browser_download_url"] as? String {
                        self.downloadURL = url
                        break
                    }
                }
            }

            let hasUpdate = self.isNewer(remoteVersion, than: self.currentVersion)
            DispatchQueue.main.async { completion?(hasUpdate) }
        }.resume()
    }

    var updateAvailable: Bool {
        guard let latest = latestVersion else { return false }
        return isNewer(latest, than: currentVersion)
    }

    var updateVersionString: String {
        return latestVersion ?? currentVersion
    }

    func downloadUpdate() {
        // If we have a .pkg URL, download and open it
        if let urlStr = downloadURL, let url = URL(string: urlStr) {
            NSWorkspace.shared.open(url)
            return
        }
        // Fallback: open releases page
        if let url = URL(string: "https://github.com/\(repo)/releases/latest") {
            NSWorkspace.shared.open(url)
        }
    }

    private func isNewer(_ remote: String, than local: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let l = local.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv > lv { return true }
            if rv < lv { return false }
        }
        return false
    }
}

// MARK: - Entry Point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()

import Cocoa

// MARK: - Colors (Maranello Luce Design System)
enum MLColor {
    static var gold: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
                ? NSColor(red: 1.0, green: 0.78, blue: 0.17, alpha: 1.0)    // #FFC72C dark
                : NSColor(red: 0.545, green: 0.42, blue: 0.0, alpha: 1.0)   // #8B6B00 light
        }
    }

    static var rosso: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
                ? NSColor(red: 0.863, green: 0.0, blue: 0.0, alpha: 1.0)    // #DC0000
                : NSColor(red: 0.667, green: 0.0, blue: 0.0, alpha: 1.0)    // #AA0000
        }
    }

    static var verde: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
                ? NSColor(red: 0.0, green: 0.651, blue: 0.318, alpha: 1.0)  // #00A651
                : NSColor(red: 0.0, green: 0.478, blue: 0.239, alpha: 1.0)  // #007A3D
        }
    }

    static var info: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
                ? NSColor(red: 0.267, green: 0.541, blue: 1.0, alpha: 1.0)  // #448AFF
                : NSColor(red: 0.0, green: 0.353, blue: 0.8, alpha: 1.0)    // #005ACC
        }
    }

    static var warning: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
                ? NSColor(red: 1.0, green: 0.702, blue: 0.0, alpha: 1.0)    // #FFB300
                : NSColor(red: 0.6, green: 0.4, blue: 0.0, alpha: 1.0)      // #996600
        }
    }

    static var grigio: NSColor { .secondaryLabelColor }
    static var dimmed: NSColor { .tertiaryLabelColor }
}

// MARK: - Text Helpers
enum MLText {
    static func header(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.menuBarFont(ofSize: 14).bold ?? NSFont.boldSystemFont(ofSize: 14),
            .foregroundColor: NSColor.labelColor
        ])
    }

    static func plain(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.menuFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor
        ])
    }

    static func colored(_ text: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.menuFont(ofSize: 13),
            .foregroundColor: color
        ])
    }

    static func bold(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.boldSystemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor
        ])
    }

    static func small(_ text: String, color: NSColor = .secondaryLabelColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.menuFont(ofSize: 11),
            .foregroundColor: color
        ])
    }

    static func dot(color: NSColor) -> NSAttributedString {
        NSAttributedString(string: "● ", attributes: [
            .font: NSFont.menuFont(ofSize: 13),
            .foregroundColor: color
        ])
    }

    static func smallDot(color: NSColor) -> NSAttributedString {
        NSAttributedString(string: "● ", attributes: [
            .font: NSFont.menuFont(ofSize: 9),
            .foregroundColor: color
        ])
    }

    /// Clean GUID-like patterns from paths for display
    static func cleanPath(_ path: String) -> String {
        let pattern = "[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}"
        return (try? NSRegularExpression(pattern: pattern, options: .caseInsensitive))?
            .stringByReplacingMatches(in: path, range: NSRange(path.startIndex..., in: path), withTemplate: "…") ?? path
    }
}

extension NSFont {
    var bold: NSFont? {
        NSFontManager.shared.convert(self, toHaveTrait: .boldFontMask)
    }
}

// MARK: - Formatting Helpers
enum Fmt {
    static func formatBytes(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024 && unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return unit == 0 ? "\(bytes) B" : String(format: "%.1f %@", value, units[unit])
    }

    static func formatDuration(_ seconds: Double) -> String {
        if seconds < 60 { return "\(Int(seconds))s" }
        if seconds < 3600 { return "\(Int(seconds / 60))m \(Int(seconds.truncatingRemainder(dividingBy: 60)))s" }
        return "\(Int(seconds / 3600))h \(Int((seconds / 60).truncatingRemainder(dividingBy: 60)))m"
    }

    static func formatFileCount(_ count: UInt64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = "."
        return formatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }

    static func timeAgo(from dateString: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: dateString) else { return dateString }
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "adesso" }
        if interval < 3600 { return "\(Int(interval / 60)) min fa" }
        if interval < 86400 { return "\(Int(interval / 3600)) ore fa" }
        return "\(Int(interval / 86400)) giorni fa"
    }
}

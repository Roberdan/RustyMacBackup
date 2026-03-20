import Cocoa

// MARK: - Colors (system-aligned, minimal)
enum MLColor {
    static var accent: NSColor { .controlAccentColor }
    static var success: NSColor { .systemGreen }
    static var warning: NSColor { .systemOrange }
    static var error: NSColor { .systemRed }
    static var secondary: NSColor { .secondaryLabelColor }
    static var tertiary: NSColor { .tertiaryLabelColor }
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
        if interval < 60 { return "now" }
        if interval < 3600 { return "\(Int(interval / 60)) min ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }
}

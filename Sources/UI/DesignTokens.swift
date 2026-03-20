import Cocoa
import SwiftUI

// MARK: - AppKit Colors (system-aligned)
enum MLColor {
    static var accent: NSColor { .controlAccentColor }
    static var success: NSColor { .systemGreen }
    static var warning: NSColor { .systemOrange }
    static var error: NSColor { .systemRed }
    static var secondary: NSColor { .secondaryLabelColor }
    static var tertiary: NSColor { .tertiaryLabelColor }

    // Maranello Luce brand colors
    static var gold: NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 1.000, green: 0.780, blue: 0.172, alpha: 1)
            : NSColor(srgbRed: 0.545, green: 0.420, blue: 0.000, alpha: 1) }
    }
    static var rosso: NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.863, green: 0.000, blue: 0.000, alpha: 1)
            : NSColor(srgbRed: 0.667, green: 0.000, blue: 0.000, alpha: 1) }
    }
    static var verde: NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.000, green: 0.651, blue: 0.318, alpha: 1)
            : NSColor(srgbRed: 0.000, green: 0.478, blue: 0.239, alpha: 1) }
    }
}

// MARK: - SwiftUI Colors (Maranello Luce)
extension Color {
    static var mlGold: Color {
        Color(NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 1.000, green: 0.780, blue: 0.172, alpha: 1)
            : NSColor(srgbRed: 0.545, green: 0.420, blue: 0.000, alpha: 1) })
    }
    static var mlRosso: Color {
        Color(NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.863, green: 0.000, blue: 0.000, alpha: 1)
            : NSColor(srgbRed: 0.667, green: 0.000, blue: 0.000, alpha: 1) })
    }
    static var mlVerde: Color {
        Color(NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.000, green: 0.651, blue: 0.318, alpha: 1)
            : NSColor(srgbRed: 0.000, green: 0.478, blue: 0.239, alpha: 1) })
    }
    static var mlInfo: Color {
        Color(NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.267, green: 0.541, blue: 1.000, alpha: 1)
            : NSColor(srgbRed: 0.000, green: 0.353, blue: 0.800, alpha: 1) })
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
        if interval < 60 { return "now" }
        if interval < 3600 { return "\(Int(interval / 60)) min ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }
}

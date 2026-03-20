import Foundation

final class ConfigParserTests {
    func test_parseFullConfig() throws {
        let toml = """
        [source]
        paths = [
            "/Users/test/.zshrc",
            "/Users/test/.gitconfig",
        ]
        [destination]
        path = "/Volumes/Backup/RustyMacBackup"
        [exclude]
        patterns = [".DS_Store", "node_modules", "*.tmp"]
        [retention]
        hourly = 12
        daily = 7
        weekly = 4
        monthly = 3
        """
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".toml")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try toml.write(to: tmp, atomically: true, encoding: .utf8)

        let config = try Config.load(from: tmp)
        try expectEqual(config.source.paths.count, 2, "paths count mismatch")
        try expectEqual(config.destination.path, "/Volumes/Backup/RustyMacBackup", "destination path mismatch")
        try expect(config.exclude.patterns.contains("node_modules"), "exclude should contain node_modules")
        try expectEqual(config.retention.hourly, 12, "hourly mismatch")
        try expectEqual(config.retention.daily, 7, "daily mismatch")
        try expectEqual(config.retention.weekly, 4, "weekly mismatch")
        try expectEqual(config.retention.monthly, 3, "monthly mismatch")
    }

    func test_defaultRetention() throws {
        let toml = """
        [source]
        paths = ["/Users/test/.zshrc"]
        [destination]
        path = "/Volumes/Backup"
        [exclude]
        patterns = []
        """
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".toml")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try toml.write(to: tmp, atomically: true, encoding: .utf8)

        let config = try Config.load(from: tmp)
        try expectEqual(config.retention.hourly, 24, "default hourly mismatch")
        try expectEqual(config.retention.daily, 30, "default daily mismatch")
        try expectEqual(config.retention.weekly, 52, "default weekly mismatch")
        try expectEqual(config.retention.monthly, 0, "default monthly mismatch")
    }

    func test_commentsIgnored() throws {
        let toml = """
        # comment
        [source]
        paths = ["/Users/test/.zshrc"]
        [destination]
        path = "/Volumes/Backup"
        [exclude]
        patterns = []
        """
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".toml")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try toml.write(to: tmp, atomically: true, encoding: .utf8)

        let config = try Config.load(from: tmp)
        try expectEqual(config.source.paths.first, "/Users/test/.zshrc", "comment handling failed")
    }

    func test_roundTrip() throws {
        let config1 = Config(
            source: SourceConfig(paths: ["/Users/test/.zshrc", "/Users/test/GitHub"]),
            destination: DestinationConfig(path: "/Volumes/Backup"),
            exclude: ExcludeConfig(patterns: ["*.tmp"]),
            retention: RetentionConfig(hourly: 24, daily: 30, weekly: 52, monthly: 0)
        )
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".toml")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try config1.save(to: tmp)

        let config2 = try Config.load(from: tmp)
        try expectEqual(config1.source.paths, config2.source.paths, "source mismatch after round-trip")
        try expectEqual(config1.destination.path, config2.destination.path, "destination mismatch after round-trip")
        try expectEqual(config1.exclude.patterns, config2.exclude.patterns, "exclude mismatch after round-trip")
        try expectEqual(config1.retention.hourly, config2.retention.hourly, "retention mismatch after round-trip")
    }

    func test_legacyConfigMigration() throws {
        let toml = """
        [source]
        path = "/Users/test"
        extra_paths = ["/etc", "/Library"]
        [destination]
        path = "/Volumes/Backup"
        [exclude]
        patterns = []
        """
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".toml")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try toml.write(to: tmp, atomically: true, encoding: .utf8)

        let config = try Config.load(from: tmp)
        // Legacy format should migrate: path + extra_paths -> paths
        try expectEqual(config.source.paths.count, 3, "legacy migration should produce 3 paths")
        try expectEqual(config.source.paths[0], "/Users/test", "legacy path should be first")
        try expectEqual(config.source.paths[1], "/etc", "extra_paths should follow")
    }
}

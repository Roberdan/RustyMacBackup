import Foundation

final class HiddenDiscoveryTests {
    func test_deniedCacheNames() throws {
        try expect(ConfigDiscovery.isDeniedName("Caches"), "Caches is not config")
        try expect(ConfigDiscovery.isDeniedName("node_modules"), "node_modules is not config")
        try expect(ConfigDiscovery.isDeniedName("chromium-profile"), "browser profile is not config")
        try expect(ConfigDiscovery.isDeniedName("m-playwright-profiles"), "-profiles suffix is not config")
        try expect(ConfigDiscovery.isDeniedName(".ado_orgs.cache"), ".cache extension is not config")
        try expect(ConfigDiscovery.isDeniedName("logs_2.sqlite-wal"), "sqlite sidecars are not config")
        try expect(ConfigDiscovery.isDeniedName(".npmrc.bak-20260830-105410"), "timestamped copies are not config")
    }

    func test_realConfigSurvives() throws {
        for name in [".zshrc", ".gitconfig", "settings.json", "config.toml", ".codex", "skills", "agents"] {
            try expect(!ConfigDiscovery.isDeniedName(name), "\(name) must stay in the backup")
        }
    }

    func test_deniedPaths() throws {
        try expect(ConfigDiscovery.isDeniedHidden(relative: ".local/share"), ".local/share is data")
        try expect(ConfigDiscovery.isDeniedHidden(relative: ".ollama"), "model store is data")
        try expect(ConfigDiscovery.isDeniedHidden(relative: ".cargo/registry"), "crate registry is data")
        try expect(ConfigDiscovery.isDeniedHidden(relative: ".gstack/chromium-profile"), "nested profile is data")
        try expect(!ConfigDiscovery.isDeniedHidden(relative: ".local/bin"), ".local/bin is user content")
        try expect(!ConfigDiscovery.isDeniedHidden(relative: ".codex"), ".codex is config")
    }

    func test_secretsStayOptIn() throws {
        let scan = ConfigDiscovery.discoverHiddenHome(measuringData: false)
        for entry in scan.configs where ["~/.ssh", "~/.gnupg", "~/.aws"].contains(entry.paths.first ?? "") {
            try expect(entry.sensitive, "\(entry.label) must be marked sensitive")
        }
    }

    func test_pruneRedundant() throws {
        let pruned = ConfigDiscovery.pruneRedundant([
            "~/.claude/agents", "~/.claude", "~/.claude/settings.json", "~/.claudex",
        ])
        try expectEqual(pruned, ["~/.claude", "~/.claudex"], "children of an included dir are dropped")
    }

    func test_sizeIgnoresExcludedContent() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let modules = root + "/node_modules"
        try FileManager.default.createDirectory(atPath: modules, withIntermediateDirectories: true)
        let big = Data(count: 4 * 1024 * 1024)
        try big.write(to: URL(fileURLWithPath: modules + "/blob.bin"))
        try Data("theme = dark".utf8).write(to: URL(fileURLWithPath: root + "/config.toml"))

        let size = ConfigDiscovery.approximateSize(atPath: root, limit: 1024 * 1024)
        try expect(size < 1024 * 1024, "node_modules must not count toward the config size, got \(size)")
    }

    private func makeTempDir() throws -> String {
        let path = NSTemporaryDirectory() + "rmb-hidden-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }
}

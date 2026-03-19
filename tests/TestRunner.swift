import Foundation

typealias TestClosure = () throws -> Void

@main
struct TestRunner {
    static func main() {
        var passed = 0
        var failed = 0
        var failedNames: [String] = []

        let exclude = ExcludeFilterTests()
        let retention = RetentionTests()
        let config = ConfigParserTests()
        let backup = BackupEngineTests()
        let hardLinker = HardLinkerTests()

        let suites: [(String, TestClosure)] = [
            ("ExcludeFilter.wildcardStar", exclude.test_wildcardStar),
            ("ExcludeFilter.wildcardQuestion", exclude.test_wildcardQuestion),
            ("ExcludeFilter.componentMatch", exclude.test_componentMatch),
            ("ExcludeFilter.pathPrefixMatch", exclude.test_pathPrefixMatch),
            ("ExcludeFilter.notExcluded", exclude.test_notExcluded),
            ("ExcludeFilter.directorySkip", exclude.test_directorySkip),
            ("ExcludeFilter.dotPatterns", exclude.test_dotPatterns),
            ("Retention.parseValid", retention.test_parseBackupName_valid),
            ("Retention.parseInvalid", retention.test_parseBackupName_invalid),
            ("Retention.keepLatest", retention.test_alwaysKeepLatest),
            ("Retention.hourly", retention.test_hourlyRetention),
            ("Retention.dryRun", retention.test_dryRunNoDeletion),
            ("Retention.monthlyForever", retention.test_monthlyForever),
            ("Config.parseFull", config.test_parseFullConfig),
            ("Config.defaults", config.test_defaultRetention),
            ("Config.comments", config.test_commentsIgnored),
            ("Config.roundTrip", config.test_roundTrip),
            ("Config.extraPaths", config.test_extraPathsParsed),
            ("BackupEngine.naming", backup.test_snapshotNaming),
            ("BackupEngine.inProgress", backup.test_inProgressPrefix),
            ("BackupEngine.statusFormat", backup.test_statusFileFormat),
            ("HardLinker.sameFile", hardLinker.test_sameFileSameSizeMtime),
            ("HardLinker.diffSize", hardLinker.test_differentSize),
            ("HardLinker.hardLink", hardLinker.test_hardLinkCreation),
            ("HardLinker.copyFile", hardLinker.test_copyFileCreation)
        ]

        print("🧪 Running RustyMacBackup tests (\(suites.count) total)...")
        for (name, test) in suites {
            do {
                try test()
                passed += 1
                print("  ✅ \(name)")
            } catch {
                failed += 1
                failedNames.append(name)
                print("  ❌ \(name): \(error)")
            }
        }

        print("\n\(passed + failed) tests, \(passed) passed, \(failed) failed")
        if !failedNames.isEmpty {
            print("Failed: \(failedNames.joined(separator: ", "))")
            exit(1)
        }
    }
}

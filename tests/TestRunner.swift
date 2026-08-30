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
        let dlp = DLPGuardTests()
        let scanner = FileScannerTests()
        let hidden = HiddenDiscoveryTests()

        let suites: [(String, TestClosure)] = [
            ("ExcludeFilter.wildcardStar", exclude.test_wildcardStar),
            ("ExcludeFilter.wildcardQuestion", exclude.test_wildcardQuestion),
            ("ExcludeFilter.componentMatch", exclude.test_componentMatch),
            ("ExcludeFilter.pathPrefixMatch", exclude.test_pathPrefixMatch),
            ("ExcludeFilter.notExcluded", exclude.test_notExcluded),
            ("ExcludeFilter.directorySkip", exclude.test_directorySkip),
            ("ExcludeFilter.dotPatterns", exclude.test_dotPatterns),
            ("HiddenDiscovery.deniedCacheNames", hidden.test_deniedCacheNames),
            ("HiddenDiscovery.realConfigSurvives", hidden.test_realConfigSurvives),
            ("HiddenDiscovery.deniedPaths", hidden.test_deniedPaths),
            ("HiddenDiscovery.secretsStayOptIn", hidden.test_secretsStayOptIn),
            ("HiddenDiscovery.pruneRedundant", hidden.test_pruneRedundant),
            ("HiddenDiscovery.sizeIgnoresExcludedContent", hidden.test_sizeIgnoresExcludedContent),
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
            ("Config.legacyMigration", config.test_legacyConfigMigration),
            ("BackupEngine.naming", backup.test_snapshotNaming),
            ("BackupEngine.inProgress", backup.test_inProgressPrefix),
            ("BackupEngine.statusFormat", backup.test_statusFileFormat),
            ("HardLinker.sameFile", hardLinker.test_sameFileSameSizeMtime),
            ("HardLinker.diffSize", hardLinker.test_differentSize),
            ("HardLinker.hardLink", hardLinker.test_hardLinkCreation),
            ("HardLinker.copyFile", hardLinker.test_copyFileCreation),
            ("DLPGuard.officeExtensions", dlp.test_officeExtensionsRecognised),
            ("DLPGuard.nonOfficeNeverSkipped", dlp.test_nonOfficeFilesAreNeverSkipped),
            ("DLPGuard.unlabeledSkipped", dlp.test_unlabeledOfficeFileIsSkipped),
            ("DLPGuard.labeledCopied", dlp.test_labeledOfficeFileIsCopied),
            ("DLPGuard.legacyUnknown", dlp.test_legacyBinaryFormatIsUnknown),
            ("DLPGuard.inactiveSkipsNothing", dlp.test_inactiveGuardSkipsNothing),
            ("DLPGuard.internalDestination", dlp.test_internalDestinationDoesNotActivateGuard),
            ("DLPGuard.hardLinkWins", dlp.test_hardLinkWinsOverDLPSkip),
            ("DLPGuard.skipsReported", dlp.test_skipsAreReportedInTheirOwnCategory),
            ("FileScanner.excludedFileKeepsSibling", scanner.test_excludedFileDoesNotSwallowSiblingDirectory),
            ("FileScanner.excludedDirPruned", scanner.test_excludedDirectoryIsStillPruned),
            ("FileScanner.multipleExcludedFiles", scanner.test_multipleExcludedFilesBeforeDirectory)
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

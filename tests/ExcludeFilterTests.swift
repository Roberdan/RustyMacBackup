import Foundation

final class ExcludeFilterTests {
    func test_wildcardStar() throws {
        try expect(ExcludeFilter.globMatch(pattern: "*.tmp", text: "file.tmp"), "*.tmp should match file.tmp")
        try expect(ExcludeFilter.globMatch(pattern: "*.tmp", text: "report.tmp"), "*.tmp should match report.tmp")
        try expect(!ExcludeFilter.globMatch(pattern: "*.tmp", text: "file.txt"), "*.tmp should not match file.txt")
        try expect(!ExcludeFilter.globMatch(pattern: "*.tmp", text: "tmp"), "*.tmp should not match tmp")
    }

    func test_wildcardQuestion() throws {
        try expect(ExcludeFilter.globMatch(pattern: "file?.txt", text: "file1.txt"), "file?.txt should match file1.txt")
        try expect(ExcludeFilter.globMatch(pattern: "file?.txt", text: "fileA.txt"), "file?.txt should match fileA.txt")
        try expect(!ExcludeFilter.globMatch(pattern: "file?.txt", text: "file12.txt"), "file?.txt should not match file12.txt")
        try expect(!ExcludeFilter.globMatch(pattern: "file?.txt", text: "file.txt"), "file?.txt should not match file.txt")
    }

    func test_componentMatch() throws {
        let filter = ExcludeFilter(patterns: ["node_modules"])
        try expect(filter.isExcluded(relativePath: "node_modules/package/index.js"), "node_modules should match at root")
        try expect(filter.isExcluded(relativePath: "projects/app/node_modules/pkg/lib.js"), "node_modules should match at depth")
        try expect(!filter.isExcluded(relativePath: "projects/app/src/main.js"), "src path should not be excluded")
    }

    func test_pathPrefixMatch() throws {
        let filter = ExcludeFilter(patterns: ["Library/Caches"])
        try expect(filter.isExcluded(relativePath: "Library/Caches/com.apple/data"), "Library/Caches prefix should match child")
        try expect(filter.isExcluded(relativePath: "Library/Caches"), "Library/Caches should match exact path")
        try expect(!filter.isExcluded(relativePath: "Library/CachesExtended/data"), "boundary prefix should not overmatch")
    }

    func test_notExcluded() throws {
        let filter = ExcludeFilter(patterns: ["*.tmp", "node_modules", ".DS_Store"])
        try expect(!filter.isExcluded(relativePath: "Documents/report.pdf"), "report.pdf should not be excluded")
        try expect(!filter.isExcluded(relativePath: "src/main.swift"), "main.swift should not be excluded")
    }

    func test_directorySkip() throws {
        let filter = ExcludeFilter(patterns: ["node_modules", "Library/Caches"])
        try expect(filter.shouldSkipDirectory(relativePath: "node_modules"), "node_modules should be skipped")
        try expect(filter.shouldSkipDirectory(relativePath: "Library/Caches"), "Library/Caches should be skipped")
        try expect(!filter.shouldSkipDirectory(relativePath: "Documents"), "Documents should not be skipped")
    }

    func test_dotPatterns() throws {
        let filter = ExcludeFilter(patterns: [".DS_Store", ".Spotlight-*"])
        try expect(filter.isExcluded(relativePath: ".DS_Store"), ".DS_Store should match")
        try expect(filter.isExcluded(relativePath: "some/dir/.DS_Store"), "nested .DS_Store should match")
        try expect(filter.isExcluded(relativePath: ".Spotlight-V100"), ".Spotlight-* should match")
    }
}

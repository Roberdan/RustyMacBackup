import Foundation

struct ExcludeFilter {
    let patterns: [String]

    init(patterns: [String]) {
        self.patterns = patterns
    }

    /// Check if a relative path should be excluded from backup.
    /// Three-level matching:
    /// 1. Full relative path match: "Library/Caches" matches "Library/Caches/foo/bar"
    /// 2. Path component match: "node_modules" matches "projects/app/node_modules/pkg/index.js"
    /// 3. Directory prefix match at boundary: ".git/objects" matches ".git/objects/pack/data"
    func isExcluded(relativePath: String) -> Bool {
        let path = Self.normalizePath(relativePath)
        let pathComponents = Self.pathComponents(path)

        for rawPattern in patterns {
            let pattern = Self.normalizePath(rawPattern)
            if pattern.isEmpty {
                continue
            }

            // 1) Full path match (glob) + direct subtree inclusion for literal paths.
            if Self.globMatch(pattern: pattern, text: path) {
                return true
            }
            if Self.isLiteralBoundaryPrefix(pattern: pattern, path: path) {
                return true
            }

            // 2) Component match.
            for component in pathComponents where Self.globMatch(pattern: pattern, text: component) {
                return true
            }

            // 3) Directory prefix match on component boundaries.
            if Self.componentPrefixMatch(pattern: pattern, path: path) {
                return true
            }
        }

        return false
    }

    /// Check if a directory should be skipped entirely (don't descend).
    /// Used by FileManager.enumerator to skip entire subtrees.
    func shouldSkipDirectory(relativePath: String) -> Bool {
        let path = Self.normalizePath(relativePath)
        let pathComponents = Self.pathComponents(path)

        for rawPattern in patterns {
            let pattern = Self.normalizePath(rawPattern)
            if pattern.isEmpty {
                continue
            }

            // Direct directory match.
            if Self.globMatch(pattern: pattern, text: path) {
                return true
            }

            // Match directory names anywhere in the current path.
            for component in pathComponents where Self.globMatch(pattern: pattern, text: component) {
                return true
            }

            // Match pattern as a path prefix at component boundaries.
            if Self.componentPrefixMatch(pattern: pattern, path: path) {
                return true
            }
        }

        return false
    }

    /// Glob pattern matching supporting * and ? wildcards.
    /// * matches any sequence of characters (including empty)
    /// ? matches exactly one character
    static func globMatch(pattern: String, text: String) -> Bool {
        let p = Array(pattern)
        let t = Array(text)
        let m = p.count
        let n = t.count

        var dp = Array(repeating: Array(repeating: false, count: n + 1), count: m + 1)
        dp[0][0] = true

        if m > 0 {
            for i in 1...m where p[i - 1] == "*" {
                dp[i][0] = dp[i - 1][0]
            }
        }

        if m > 0, n > 0 {
            for i in 1...m {
                for j in 1...n {
                    let pc = p[i - 1]
                    let tc = t[j - 1]

                    if pc == "*" {
                        // '*' cannot cross path separators.
                        dp[i][j] = dp[i - 1][j] || (tc != "/" && dp[i][j - 1])
                    } else if pc == "?" {
                        // '?' cannot match path separators.
                        dp[i][j] = tc != "/" && dp[i - 1][j - 1]
                    } else {
                        dp[i][j] = (pc == tc) && dp[i - 1][j - 1]
                    }
                }
            }
        }

        return dp[m][n]
    }

    private static func normalizePath(_ value: String) -> String {
        var path = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while path.hasPrefix("./") {
            path.removeFirst(2)
        }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path == "." ? "" : path
    }

    private static func pathComponents(_ path: String) -> [String] {
        guard !path.isEmpty else {
            return []
        }
        return path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    private static func hasWildcards(_ pattern: String) -> Bool {
        pattern.contains("*") || pattern.contains("?")
    }

    private static func isLiteralBoundaryPrefix(pattern: String, path: String) -> Bool {
        guard !pattern.isEmpty, !hasWildcards(pattern) else {
            return false
        }
        if pattern == path {
            return true
        }
        guard path.count > pattern.count, path.hasPrefix(pattern) else {
            return false
        }
        let idx = path.index(path.startIndex, offsetBy: pattern.count)
        return path[idx] == "/"
    }

    private static func componentPrefixMatch(pattern: String, path: String) -> Bool {
        let patternComponents = pathComponents(pattern)
        let pathComponents = pathComponents(path)

        guard !patternComponents.isEmpty, patternComponents.count <= pathComponents.count else {
            return false
        }

        for (p, t) in zip(patternComponents, pathComponents) where !globMatch(pattern: p, text: t) {
            return false
        }

        return true
    }
}

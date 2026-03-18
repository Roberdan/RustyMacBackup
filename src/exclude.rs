use glob_match::glob_match;
use std::path::Path;

pub struct ExcludeFilter {
    patterns: Vec<String>,
}

impl ExcludeFilter {
    pub fn new(patterns: &[String]) -> Self {
        Self {
            patterns: patterns.to_vec(),
        }
    }

    pub fn is_excluded(&self, relative_path: &Path) -> bool {
        let path_str = relative_path.to_string_lossy();
        for pattern in &self.patterns {
            // Match against full relative path
            if glob_match(pattern, &path_str) {
                return true;
            }
            // Match against each component (e.g. "node_modules" matches any depth)
            for component in relative_path.components() {
                let comp_str = component.as_os_str().to_string_lossy();
                if glob_match(pattern, &comp_str) {
                    return true;
                }
            }
            // Check if path starts with pattern (directory prefix match)
            // Require match at a path boundary to avoid false positives
            // (e.g. "Library/Developer" should NOT match "Library/DeveloperExtra")
            if path_str.starts_with(pattern.as_str()) {
                if path_str.len() == pattern.len()
                    || path_str.as_bytes().get(pattern.len()) == Some(&b'/')
                {
                    return true;
                }
            }
        }
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    #[test]
    fn test_exclude_node_modules() {
        let filter = ExcludeFilter::new(&["node_modules".to_string()]);
        assert!(filter.is_excluded(&PathBuf::from("project/node_modules/package/index.js")));
    }

    #[test]
    fn test_exclude_ds_store() {
        let filter = ExcludeFilter::new(&["*.DS_Store".to_string()]);
        assert!(filter.is_excluded(&PathBuf::from(".DS_Store")));
    }

    #[test]
    fn test_not_excluded() {
        let filter = ExcludeFilter::new(&["node_modules".to_string()]);
        assert!(!filter.is_excluded(&PathBuf::from("src/main.rs")));
    }

    #[test]
    fn test_glob_pattern() {
        let filter = ExcludeFilter::new(&["target/debug".to_string()]);
        assert!(filter.is_excluded(&PathBuf::from("target/debug/build/something")));
    }
}

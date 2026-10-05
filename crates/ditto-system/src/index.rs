//! The desktop-entry index: every `applications/` directory in XDG
//! precedence order, parsed once and kept by file `(mtime, size)`, so a
//! rescan after an inotify event only stats unchanged files. The on-disk copy
//! at `$XDG_CACHE_HOME/ditto/app-index.db` is a rebuildable cache: deleting
//! it costs one full parse, and nothing reads it as configuration.

use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::io::{self, Write};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use ditto_protocol::services::AppEntry;
use serde::{Deserialize, Serialize};

use crate::desktop_entry::{self, DesktopEntry, Locale};

const CACHE_VERSION: u32 = 1;
/// Deeper trees exist only through symlink loops; the spec has no depth limit.
const MAX_DEPTH: usize = 8;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct FileRecord {
    pub mtime_ns: i128,
    pub size: u64,
    /// `None`: the file exists but is not a valid entry. It still masks.
    pub entry: Option<DesktopEntry>,
}

#[derive(Serialize, Deserialize)]
struct CacheFile {
    version: u32,
    files: BTreeMap<PathBuf, FileRecord>,
}

/// What decides visibility besides the file itself.
#[derive(Clone, Debug, Default)]
pub struct Environment {
    /// `$XDG_CURRENT_DESKTOP`, split on `:`.
    pub desktops: Vec<String>,
    /// `$PATH`, for `TryExec`.
    pub path: Vec<PathBuf>,
}

impl Environment {
    pub fn from_env() -> Self {
        Self {
            desktops: std::env::var("XDG_CURRENT_DESKTOP")
                .unwrap_or_default()
                .split(':')
                .filter(|d| !d.is_empty())
                .map(String::from)
                .collect(),
            path: std::env::var_os("PATH")
                .map(|p| std::env::split_paths(&p).collect())
                .unwrap_or_default(),
        }
    }

    fn executable(&self, program: &str) -> bool {
        let is_exec = |path: &Path| {
            fs::metadata(path).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
        };
        if program.contains('/') {
            return is_exec(Path::new(program));
        }
        self.path.iter().any(|dir| is_exec(&dir.join(program)))
    }
}

#[derive(Clone, Debug)]
pub struct Indexed {
    /// Desktop file id without `.desktop`: the `app_id` of the contract.
    pub app_id: String,
    pub path: PathBuf,
    pub entry: DesktopEntry,
    /// False for `NoDisplay`, `OnlyShowIn`/`NotShowIn` misses: still
    /// launchable (a MIME handler often is `NoDisplay`), never listed.
    pub listed: bool,
}

#[derive(Default)]
pub struct AppIndex {
    pub files: BTreeMap<PathBuf, FileRecord>,
    pub apps: HashMap<String, Indexed>,
    pub indexed_at: Option<SystemTime>,
}

impl AppIndex {
    pub fn load_cache(path: &Path) -> BTreeMap<PathBuf, FileRecord> {
        fs::read(path)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<CacheFile>(&bytes).ok())
            .filter(|cache| cache.version == CACHE_VERSION)
            .map(|cache| cache.files)
            .unwrap_or_default()
    }

    /// Walk `dirs` (highest precedence first), reusing records whose file is
    /// unchanged. The first file with a given id wins even when it is hidden
    /// or invalid, which is how a user entry deletes a system one.
    pub fn scan(
        dirs: &[PathBuf],
        previous: &BTreeMap<PathBuf, FileRecord>,
        env: &Environment,
    ) -> Self {
        let mut files = BTreeMap::new();
        let mut apps = HashMap::new();
        let mut seen = std::collections::HashSet::new();
        for dir in dirs {
            let mut found = Vec::new();
            walk(dir, 0, &mut found);
            found.sort();
            for file in found {
                let Some(id) = desktop_entry::desktop_id(dir, &file) else {
                    continue;
                };
                let Ok(meta) = fs::metadata(&file) else {
                    continue;
                };
                let mtime_ns =
                    i128::from(meta.mtime()) * 1_000_000_000 + i128::from(meta.mtime_nsec());
                let record = match previous.get(&file) {
                    Some(record) if record.mtime_ns == mtime_ns && record.size == meta.len() => {
                        record.clone()
                    }
                    _ => FileRecord {
                        mtime_ns,
                        size: meta.len(),
                        entry: fs::read_to_string(&file)
                            .ok()
                            .and_then(|text| desktop_entry::parse(&text)),
                    },
                };
                let first = seen.insert(id.clone());
                if first {
                    if let Some(entry) = &record.entry {
                        let launchable = entry.kind == "Application"
                            && !entry.hidden
                            && entry.exec.is_some()
                            && entry
                                .try_exec
                                .as_deref()
                                .is_none_or(|program| env.executable(program));
                        if launchable {
                            let app_id = id.trim_end_matches(".desktop").to_string();
                            apps.insert(
                                app_id.clone(),
                                Indexed {
                                    app_id,
                                    path: file.clone(),
                                    listed: !entry.no_display && entry.shown_in(&env.desktops),
                                    entry: entry.clone(),
                                },
                            );
                        }
                    }
                }
                files.insert(file, record);
            }
        }
        Self {
            files,
            apps,
            indexed_at: Some(SystemTime::now()),
        }
    }

    /// Atomic replace, so a crash mid-write leaves the old cache or none.
    pub fn persist(&self, path: &Path) -> io::Result<()> {
        let parent = path
            .parent()
            .ok_or_else(|| io::Error::other("cache path has no parent"))?;
        fs::create_dir_all(parent)?;
        let temporary = parent.join(format!(".app-index.{}.tmp", std::process::id()));
        let cache = CacheFile {
            version: CACHE_VERSION,
            files: self.files.clone(),
        };
        let mut file = fs::File::create(&temporary)?;
        file.write_all(&serde_json::to_vec(&cache).map_err(io::Error::other)?)?;
        file.sync_all()?;
        fs::rename(&temporary, path)
    }

    pub fn to_app_entry(indexed: &Indexed, locale: &Locale) -> AppEntry {
        let entry = &indexed.entry;
        AppEntry {
            app_id: indexed.app_id.clone(),
            name: entry.name.get(locale).to_string(),
            generic_name: entry
                .generic_name
                .as_ref()
                .map(|g| g.get(locale).to_string()),
            icon: entry.icon.clone(),
            categories: entry.categories.clone(),
            keywords: entry.keywords(locale),
        }
    }

    pub fn list(&self, category: Option<&str>, locale: &Locale) -> Vec<AppEntry> {
        let mut apps: Vec<AppEntry> = self
            .apps
            .values()
            .filter(|app| app.listed)
            .filter(|app| category.is_none_or(|c| app.entry.categories.iter().any(|own| own == c)))
            .map(|app| Self::to_app_entry(app, locale))
            .collect();
        apps.sort_by(|a, b| {
            a.name
                .to_lowercase()
                .cmp(&b.name.to_lowercase())
                .then(a.app_id.cmp(&b.app_id))
        });
        apps
    }

    pub fn search(&self, query: &str, limit: usize, locale: &Locale) -> Vec<AppEntry> {
        let terms: Vec<Vec<char>> = query
            .split_whitespace()
            .map(fold)
            .filter(|t| !t.is_empty())
            .collect();
        if terms.is_empty() {
            let mut all = self.list(None, locale);
            all.truncate(limit);
            return all;
        }
        let mut scored: Vec<(i64, AppEntry)> = self
            .apps
            .values()
            .filter(|app| app.listed)
            .filter_map(|app| {
                let entry = Self::to_app_entry(app, locale);
                let fields = search_fields(app, &entry);
                // Every term must match some field; the weakest term decides,
                // so "text editor" does not rank an app that only says "text".
                let score = terms
                    .iter()
                    .map(|term| {
                        fields
                            .iter()
                            .filter_map(|(text, weight)| score(term, text).map(|s| s * weight))
                            .max()
                    })
                    .try_fold(i64::MAX, |acc, best| best.map(|b| acc.min(b)))?;
                Some((score, entry))
            })
            .collect();
        scored.sort_by(|(sa, a), (sb, b)| {
            sb.cmp(sa)
                .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
                .then(a.app_id.cmp(&b.app_id))
        });
        scored
            .into_iter()
            .take(limit)
            .map(|(_, entry)| entry)
            .collect()
    }
}

fn walk(dir: &Path, depth: usize, out: &mut Vec<PathBuf>) {
    if depth > MAX_DEPTH {
        return;
    }
    let Ok(read) = fs::read_dir(dir) else { return };
    for item in read.flatten() {
        let path = item.path();
        match fs::metadata(&path) {
            Ok(meta) if meta.is_dir() => walk(&path, depth + 1, out),
            Ok(meta) if meta.is_file() && path.extension().is_some_and(|e| e == "desktop") => {
                out.push(path)
            }
            _ => {}
        }
    }
}

/// Case-folded characters. Lowercasing is per `char`, so CJK text passes
/// through unchanged and matching never splits a multi-byte character.
fn fold(text: &str) -> Vec<char> {
    text.chars().flat_map(char::to_lowercase).collect()
}

/// Weighted fields: the translated name first, then the untranslated one (an
/// English query still finds a translated entry), generic name, keywords, id.
fn search_fields(app: &Indexed, entry: &AppEntry) -> Vec<(Vec<char>, i64)> {
    let mut fields = vec![(fold(&entry.name), 10)];
    if app.entry.name.default != entry.name {
        fields.push((fold(&app.entry.name.default), 9));
    }
    if let Some(generic) = &entry.generic_name {
        fields.push((fold(generic), 7));
    }
    if let Some(generic) = &app.entry.generic_name {
        if Some(&generic.default) != entry.generic_name.as_ref() {
            fields.push((fold(&generic.default), 6));
        }
    }
    fields.extend(entry.keywords.iter().map(|k| (fold(k), 6)));
    if let Some(untranslated) = app.entry.keywords.get("") {
        if *untranslated != entry.keywords {
            fields.extend(untranslated.iter().map(|k| (fold(k), 5)));
        }
    }
    fields.push((fold(&entry.app_id), 5));
    fields
}

fn is_boundary(text: &[char], index: usize) -> bool {
    index == 0 || {
        let previous = text[index - 1];
        let current = text[index];
        !previous.is_alphanumeric() || (!current.is_ascii() && current.is_alphanumeric())
    }
}

/// Exact > prefix > word prefix > substring > subsequence; `None` when the
/// query characters do not all appear in order.
pub fn score(query: &[char], text: &[char]) -> Option<i64> {
    if query.is_empty() || query.len() > text.len() {
        return None;
    }
    if query == text {
        return Some(1000);
    }
    let length_penalty = (text.len() - query.len()).min(50) as i64;
    if text.starts_with(query) {
        return Some(800 - length_penalty);
    }
    let positions: Vec<usize> = (0..=text.len() - query.len())
        .filter(|&i| text[i..].starts_with(query))
        .collect();
    if let Some(&at) = positions.iter().find(|&&i| is_boundary(text, i)) {
        return Some(600 - at.min(50) as i64 - length_penalty / 2);
    }
    if let Some(&at) = positions.first() {
        return Some(400 - at.min(50) as i64 - length_penalty / 2);
    }
    let mut score = 100i64;
    let mut next = 0;
    let mut previous: Option<usize> = None;
    for &c in query {
        let found = (next..text.len()).find(|&i| text[i] == c)?;
        if previous.is_some_and(|p| p + 1 == found) {
            score += 10;
        } else if let Some(p) = previous {
            score -= (found - p - 1).min(10) as i64;
        }
        if is_boundary(text, found) {
            score += 15;
        }
        previous = Some(found);
        next = found + 1;
    }
    Some(score.clamp(1, 399))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write(dir: &Path, name: &str, body: &str) {
        let path = dir.join(name);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, format!("[Desktop Entry]\nType=Application\n{body}")).unwrap();
    }

    struct Fixture {
        root: PathBuf,
        home: PathBuf,
        system: PathBuf,
        local: PathBuf,
    }

    impl Fixture {
        fn new(name: &str) -> Self {
            let root = std::env::temp_dir()
                .join(format!("ditto-system-index-{name}-{}", std::process::id()));
            let _ = fs::remove_dir_all(&root);
            let fixture = Self {
                home: root.join("home/applications"),
                local: root.join("usr-local/applications"),
                system: root.join("usr/applications"),
                root,
            };
            for dir in [&fixture.home, &fixture.local, &fixture.system] {
                fs::create_dir_all(dir).unwrap();
            }
            fixture
        }
        fn dirs(&self) -> Vec<PathBuf> {
            vec![self.home.clone(), self.local.clone(), self.system.clone()]
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    fn env(desktops: &[&str], path: Vec<PathBuf>) -> Environment {
        Environment {
            desktops: desktops.iter().map(|d| d.to_string()).collect(),
            path,
        }
    }

    #[test]
    fn precedence_hidden_and_visibility() {
        let f = Fixture::new("precedence");
        write(
            &f.system,
            "firefox.desktop",
            "Name=System Firefox\nExec=firefox\n",
        );
        write(
            &f.local,
            "firefox.desktop",
            "Name=Local Firefox\nExec=firefox\n",
        );
        write(&f.system, "foot.desktop", "Name=Foot\nExec=foot\n");
        // A user file with Hidden=true deletes the system entry.
        write(&f.system, "gone.desktop", "Name=Gone\nExec=gone\n");
        write(&f.home, "gone.desktop", "Hidden=true\n");
        // An invalid higher-precedence file masks as well.
        write(&f.system, "broken.desktop", "Name=Broken\nExec=broken\n");
        fs::write(f.local.join("broken.desktop"), "not a desktop file").unwrap();
        write(
            &f.system,
            "handler.desktop",
            "Name=Handler\nExec=handler %u\nNoDisplay=true\n",
        );
        write(
            &f.system,
            "kde-only.desktop",
            "Name=KDE Only\nExec=k\nOnlyShowIn=KDE;\n",
        );
        write(
            &f.system,
            "not-wayfire.desktop",
            "Name=Not Wayfire\nExec=n\nNotShowIn=Wayfire;\n",
        );
        fs::write(
            f.system.join("link.desktop"),
            "[Desktop Entry]\nType=Link\nName=Link\nURL=https://x\n",
        )
        .unwrap();
        write(&f.system, "kde4/kate.desktop", "Name=Kate\nExec=kate %U\n");
        write(&f.system, "noexec.desktop", "Name=No Exec\n");

        let index = AppIndex::scan(
            &f.dirs(),
            &BTreeMap::new(),
            &env(&["Wayfire", "Ditto"], vec![]),
        );
        assert_eq!(index.apps["firefox"].entry.name.default, "Local Firefox");
        assert!(!index.apps.contains_key("gone"));
        assert!(!index.apps.contains_key("broken"));
        assert!(!index.apps.contains_key("link"));
        assert!(!index.apps.contains_key("noexec"));
        assert!(index.apps.contains_key("kde4-kate"));
        assert!(
            !index.apps["handler"].listed,
            "NoDisplay is launchable but not listed"
        );
        assert!(!index.apps["kde-only"].listed);
        assert!(!index.apps["not-wayfire"].listed);
        let listed: Vec<String> = index
            .list(None, &Locale::default())
            .into_iter()
            .map(|a| a.app_id)
            .collect();
        assert_eq!(listed, ["foot", "kde4-kate", "firefox"]);
    }

    #[test]
    fn try_exec_needs_an_executable() {
        let f = Fixture::new("tryexec");
        let bin = f.root.join("bin");
        fs::create_dir_all(&bin).unwrap();
        fs::write(bin.join("present"), "#!/bin/sh\n").unwrap();
        fs::set_permissions(bin.join("present"), fs::Permissions::from_mode(0o755)).unwrap();
        fs::write(bin.join("not-exec"), "").unwrap();
        write(
            &f.system,
            "a.desktop",
            "Name=A\nExec=present\nTryExec=present\n",
        );
        write(
            &f.system,
            "b.desktop",
            "Name=B\nExec=missing\nTryExec=missing\n",
        );
        write(&f.system, "c.desktop", "Name=C\nExec=x\nTryExec=not-exec\n");
        write(
            &f.system,
            "d.desktop",
            &format!(
                "Name=D\nExec=x\nTryExec={}\n",
                bin.join("present").display()
            ),
        );
        let index = AppIndex::scan(&f.dirs(), &BTreeMap::new(), &env(&[], vec![bin]));
        let mut ids: Vec<&String> = index.apps.keys().collect();
        ids.sort();
        assert_eq!(ids, ["a", "d"]);
    }

    #[test]
    fn rescan_reuses_unchanged_records_and_cache_round_trips() {
        let f = Fixture::new("cache");
        write(&f.system, "foot.desktop", "Name=Foot\nExec=foot\n");
        let first = AppIndex::scan(&f.dirs(), &BTreeMap::new(), &Environment::default());
        let cache = f.root.join("cache/ditto/app-index.db");
        first.persist(&cache).unwrap();
        let mut loaded = AppIndex::load_cache(&cache);
        assert_eq!(loaded, first.files);
        // A poisoned cached record proves the rescan used it rather than reparsing.
        let record = loaded.values_mut().next().unwrap();
        record.entry.as_mut().unwrap().name.default = "From Cache".into();
        let second = AppIndex::scan(&f.dirs(), &loaded, &Environment::default());
        assert_eq!(second.apps["foot"].entry.name.default, "From Cache");
        // A changed file is parsed again.
        write(
            &f.system,
            "foot.desktop",
            "Name=Foot Terminal Emulator\nExec=foot\n",
        );
        let third = AppIndex::scan(&f.dirs(), &loaded, &Environment::default());
        assert_eq!(
            third.apps["foot"].entry.name.default,
            "Foot Terminal Emulator"
        );
        fs::write(&cache, "{\"version\":999,\"files\":{}}").unwrap();
        assert!(AppIndex::load_cache(&cache).is_empty());
    }

    #[test]
    fn scoring_order() {
        let s = |q: &str, t: &str| score(&fold(q), &fold(t));
        assert!(s("kate", "kate") > s("kate", "kate editor"));
        assert!(s("fire", "firefox") > s("fox", "firefox"));
        assert!(s("brow", "web browser") > s("rows", "web browser"));
        assert!(s("rows", "web browser") > s("wbr", "web browser"));
        assert_eq!(s("xyz", "firefox"), None);
        assert_eq!(s("FIRE", "Firefox"), s("fire", "firefox"));
        // CJK: character-wise prefix, word prefix and subsequence.
        assert!(s("網頁", "網頁瀏覽器").is_some());
        assert!(s("瀏覽", "網頁瀏覽器").unwrap() >= 400);
        assert!(s("網覽", "網頁瀏覽器").is_some());
        assert_eq!(s("編輯", "網頁瀏覽器"), None);
    }

    #[test]
    fn search_ranks_and_localizes() {
        let f = Fixture::new("search");
        write(
            &f.system,
            "firefox.desktop",
            "Name=Firefox\nName[zh_TW]=Firefox 網頁瀏覽器\nGenericName=Web Browser\nKeywords=Internet;WWW;\nExec=firefox %u\n",
        );
        write(
            &f.system,
            "org.kde.kate.desktop",
            "Name=Kate\nGenericName=Advanced Text Editor\nGenericName[zh_TW]=進階文字編輯器\nExec=kate %U\n",
        );
        write(
            &f.system,
            "foot.desktop",
            "Name=Foot\nGenericName=Terminal\nKeywords=shell;prompt;\nExec=foot\n",
        );
        write(
            &f.system,
            "hidden-browser.desktop",
            "Name=Hidden Browser\nExec=h\nNoDisplay=true\n",
        );
        let index = AppIndex::scan(&f.dirs(), &BTreeMap::new(), &Environment::default());
        let zh = Locale::parse("zh_TW.UTF-8");
        let ids = |query: &str, locale: &Locale| -> Vec<String> {
            index
                .search(query, 10, locale)
                .into_iter()
                .map(|a| a.app_id)
                .collect()
        };
        assert_eq!(ids("fire", &Locale::default()), ["firefox"]);
        assert_eq!(ids("瀏覽", &zh), ["firefox"]);
        assert_eq!(ids("編輯", &zh), ["org.kde.kate"]);
        assert_eq!(
            ids("editor", &zh),
            ["org.kde.kate"],
            "untranslated generic name still matches"
        );
        assert_eq!(ids("kate", &Locale::default()), ["org.kde.kate"]);
        assert_eq!(ids("shell", &Locale::default()), ["foot"]);
        assert_eq!(
            ids("browser", &Locale::default()),
            ["firefox"],
            "NoDisplay entries are not searchable"
        );
        assert_eq!(ids("text editor", &Locale::default()), ["org.kde.kate"]);
        assert!(ids("text shell", &Locale::default()).is_empty());
        assert_eq!(index.search("", 2, &Locale::default()).len(), 2);
        let firefox = &index.search("fire", 1, &zh)[0];
        assert_eq!(firefox.name, "Firefox 網頁瀏覽器");
    }
}

//! Desktop Entry Specification 1.5 parsing: the `[Desktop Entry]` group,
//! string unescaping, localized keys, and `Exec` expansion. Only what a
//! launcher needs is kept; actions, `DBusActivatable` activation and
//! `StartupNotify` are not implemented (activation goes through
//! `xdg_activation_v1` tokens instead).

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

/// A value with its `Key[locale]` translations.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Localized {
    pub default: String,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub translations: BTreeMap<String, String>,
}

impl Localized {
    /// Spec §5 lookup order: `lang_COUNTRY@MODIFIER`, `lang_COUNTRY`,
    /// `lang@MODIFIER`, `lang`, then the untranslated value.
    pub fn get(&self, locale: &Locale) -> &str {
        locale
            .candidates()
            .iter()
            .find_map(|key| self.translations.get(key))
            .map_or(self.default.as_str(), String::as_str)
    }
}

/// A POSIX locale name without its encoding, e.g. `zh_TW` from `zh_TW.UTF-8`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Locale {
    lang: String,
    country: Option<String>,
    modifier: Option<String>,
}

impl Locale {
    pub fn parse(name: &str) -> Self {
        let (rest, modifier) = match name.split_once('@') {
            Some((rest, modifier)) => (rest, Some(modifier.to_string())),
            None => (name, None),
        };
        let rest = rest.split('.').next().unwrap_or_default();
        let (lang, country) = match rest.split_once('_') {
            Some((lang, country)) => (lang.to_string(), Some(country.to_string())),
            None => (rest.to_string(), None),
        };
        if lang == "C" || lang == "POSIX" {
            return Self::default();
        }
        Self {
            lang,
            country,
            modifier,
        }
    }

    /// `LC_ALL`, then `LC_MESSAGES`, then `LANG`, as gettext resolves it.
    pub fn from_env() -> Self {
        ["LC_ALL", "LC_MESSAGES", "LANG"]
            .iter()
            .find_map(|key| std::env::var(key).ok().filter(|value| !value.is_empty()))
            .map(|value| Self::parse(&value))
            .unwrap_or_default()
    }

    fn candidates(&self) -> Vec<String> {
        if self.lang.is_empty() {
            return Vec::new();
        }
        let mut keys = Vec::with_capacity(4);
        if let (Some(country), Some(modifier)) = (&self.country, &self.modifier) {
            keys.push(format!("{}_{country}@{modifier}", self.lang));
        }
        if let Some(country) = &self.country {
            keys.push(format!("{}_{country}", self.lang));
        }
        if let Some(modifier) = &self.modifier {
            keys.push(format!("{}@{modifier}", self.lang));
        }
        keys.push(self.lang.clone());
        keys
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct DesktopEntry {
    pub kind: String,
    pub name: Localized,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub generic_name: Option<Localized>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub icon: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exec: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub try_exec: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub working_dir: Option<String>,
    #[serde(default)]
    pub terminal: bool,
    #[serde(default)]
    pub categories: Vec<String>,
    /// Keywords per locale key; `""` holds the untranslated list.
    #[serde(default)]
    pub keywords: BTreeMap<String, Vec<String>>,
    #[serde(default)]
    pub mime_types: Vec<String>,
    #[serde(default)]
    pub hidden: bool,
    #[serde(default)]
    pub no_display: bool,
    #[serde(default)]
    pub only_show_in: Vec<String>,
    #[serde(default)]
    pub not_show_in: Vec<String>,
}

impl DesktopEntry {
    pub fn keywords(&self, locale: &Locale) -> Vec<String> {
        locale
            .candidates()
            .iter()
            .find_map(|key| self.keywords.get(key))
            .or_else(|| self.keywords.get(""))
            .cloned()
            .unwrap_or_default()
    }

    /// `OnlyShowIn`/`NotShowIn` against `$XDG_CURRENT_DESKTOP` (spec §6).
    pub fn shown_in(&self, desktops: &[String]) -> bool {
        if !self.only_show_in.is_empty() && !self.only_show_in.iter().any(|d| desktops.contains(d))
        {
            return false;
        }
        !self.not_show_in.iter().any(|d| desktops.contains(d))
    }
}

/// Parse the `[Desktop Entry]` group. `None` when the group or a required key
/// (`Type`, `Name`) is missing: such a file is invalid and is skipped, but it
/// still masks lower-precedence files with the same id.
pub fn parse(text: &str) -> Option<DesktopEntry> {
    let mut in_group = false;
    let mut seen_group = false;
    let mut entry = DesktopEntry::default();
    let mut name = None;
    let mut generic = Localized::default();
    let mut has_generic = false;
    for raw in text.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if line.starts_with('[') {
            if in_group {
                break;
            }
            in_group = line == "[Desktop Entry]";
            seen_group |= in_group;
            continue;
        }
        if !in_group {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let (key, value) = (key.trim(), value.trim());
        let (base, locale) = match key.split_once('[') {
            Some((base, rest)) => (base, rest.strip_suffix(']')),
            None => (key, None),
        };
        match (base, locale) {
            ("Type", None) => entry.kind = unescape(value),
            ("Name", None) => name.get_or_insert_with(Localized::default).default = unescape(value),
            ("Name", Some(locale)) => {
                name.get_or_insert_with(Localized::default)
                    .translations
                    .insert(locale.into(), unescape(value));
            }
            ("GenericName", None) => {
                has_generic = true;
                generic.default = unescape(value);
            }
            ("GenericName", Some(locale)) => {
                has_generic = true;
                generic.translations.insert(locale.into(), unescape(value));
            }
            ("Keywords", locale) => {
                entry
                    .keywords
                    .insert(locale.unwrap_or_default().into(), list(value));
            }
            ("Icon", None) => entry.icon = Some(unescape(value)).filter(|v| !v.is_empty()),
            ("Exec", None) => entry.exec = Some(unescape(value)).filter(|v| !v.is_empty()),
            ("TryExec", None) => entry.try_exec = Some(unescape(value)).filter(|v| !v.is_empty()),
            ("Path", None) => entry.working_dir = Some(unescape(value)).filter(|v| !v.is_empty()),
            ("Terminal", None) => entry.terminal = value == "true",
            ("Categories", None) => entry.categories = list(value),
            ("MimeType", None) => entry.mime_types = list(value),
            ("Hidden", None) => entry.hidden = value == "true",
            ("NoDisplay", None) => entry.no_display = value == "true",
            ("OnlyShowIn", None) => entry.only_show_in = list(value),
            ("NotShowIn", None) => entry.not_show_in = list(value),
            _ => {}
        }
    }
    if !seen_group || entry.kind.is_empty() {
        return None;
    }
    // A hidden entry needs no name: it exists only to mask others.
    entry.name = match name {
        Some(name) => name,
        None if entry.hidden => Localized::default(),
        None => return None,
    };
    if has_generic {
        entry.generic_name = Some(generic);
    }
    Some(entry)
}

/// Spec §4 string escapes: `\s`, `\n`, `\t`, `\r`, `\\`.
fn unescape(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    let mut chars = value.chars();
    while let Some(c) = chars.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match chars.next() {
            Some('s') => out.push(' '),
            Some('n') => out.push('\n'),
            Some('t') => out.push('\t'),
            Some('r') => out.push('\r'),
            Some('\\') => out.push('\\'),
            Some(other) => {
                out.push('\\');
                out.push(other);
            }
            None => out.push('\\'),
        }
    }
    out
}

/// A `;`-separated list where `\;` is a literal semicolon.
fn list(value: &str) -> Vec<String> {
    let mut items = Vec::new();
    let mut current = String::new();
    let mut chars = value.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '\\' if chars.peek() == Some(&';') => {
                current.push(';');
                chars.next();
            }
            ';' => items.push(std::mem::take(&mut current)),
            _ => current.push(c),
        }
    }
    items.push(current);
    items
        .into_iter()
        .map(|item| unescape(item.trim()))
        .filter(|item| !item.is_empty())
        .collect()
}

/// The desktop file id (spec: path below `applications/`, `/` → `-`).
pub fn desktop_id(applications_dir: &Path, file: &Path) -> Option<String> {
    let relative = file.strip_prefix(applications_dir).ok()?;
    let text = relative.to_str()?;
    text.ends_with(".desktop").then(|| text.replace('/', "-"))
}

/// What the `Exec` line receives for this launch.
#[derive(Clone, Debug, Default)]
pub struct ExecContext<'a> {
    /// One URI or absolute path; the launcher starts one instance per target.
    pub target: Option<&'a str>,
    pub icon: Option<&'a str>,
    pub translated_name: &'a str,
    pub desktop_file: Option<&'a Path>,
}

#[derive(Debug, PartialEq, Eq)]
pub enum ExecError {
    Empty,
    UnterminatedQuote,
    /// The file named by `%f` is not local (a network URI).
    NonLocalFile(String),
}

/// Split and expand an `Exec` value (spec §7). Field codes in a quoted
/// argument are expanded inline as well, although the spec forbids them
/// there: entries in the wild use `sh -c "… %u"` and dropping the code would
/// silently launch without the target.
pub fn expand_exec(exec: &str, context: &ExecContext<'_>) -> Result<Vec<String>, ExecError> {
    let mut args = Vec::new();
    for (token, quoted) in split_exec(exec)? {
        if !quoted {
            match token.as_str() {
                "%f" | "%F" => {
                    if let Some(target) = context.target {
                        args.push(as_file(target)?);
                    }
                    continue;
                }
                "%u" | "%U" => {
                    if let Some(target) = context.target {
                        args.push(as_uri(target));
                    }
                    continue;
                }
                "%i" => {
                    if let Some(icon) = context.icon {
                        args.push("--icon".into());
                        args.push(icon.into());
                    }
                    continue;
                }
                _ => {}
            }
        }
        let mut out = String::new();
        let mut chars = token.chars();
        while let Some(c) = chars.next() {
            if c != '%' {
                out.push(c);
                continue;
            }
            match chars.next() {
                Some('%') => out.push('%'),
                Some('f' | 'F') => {
                    if let Some(target) = context.target {
                        out.push_str(&as_file(target)?);
                    }
                }
                Some('u' | 'U') => {
                    if let Some(target) = context.target {
                        out.push_str(&as_uri(target));
                    }
                }
                Some('c') => out.push_str(context.translated_name),
                Some('k') => {
                    if let Some(path) = context.desktop_file {
                        out.push_str(&path.to_string_lossy());
                    }
                }
                Some('i') => out.push_str(context.icon.unwrap_or_default()),
                // Deprecated (%d %D %n %N %v %m) and unknown codes are removed.
                _ => {}
            }
        }
        if quoted || !out.is_empty() {
            args.push(out);
        }
    }
    if args.is_empty() {
        return Err(ExecError::Empty);
    }
    Ok(args)
}

fn split_exec(exec: &str) -> Result<Vec<(String, bool)>, ExecError> {
    let mut tokens = Vec::new();
    let mut current = String::new();
    let mut quoted = false;
    let mut in_quotes = false;
    let mut chars = exec.chars();
    while let Some(c) = chars.next() {
        if in_quotes {
            match c {
                '"' => in_quotes = false,
                '\\' => match chars.next() {
                    Some(next @ ('"' | '`' | '$' | '\\')) => current.push(next),
                    Some(next) => {
                        current.push('\\');
                        current.push(next);
                    }
                    None => return Err(ExecError::UnterminatedQuote),
                },
                _ => current.push(c),
            }
            continue;
        }
        match c {
            '"' => {
                in_quotes = true;
                quoted = true;
            }
            ' ' | '\t' => {
                if !current.is_empty() || quoted {
                    tokens.push((std::mem::take(&mut current), quoted));
                }
                quoted = false;
            }
            _ => current.push(c),
        }
    }
    if in_quotes {
        return Err(ExecError::UnterminatedQuote);
    }
    if !current.is_empty() || quoted {
        tokens.push((current, quoted));
    }
    Ok(tokens)
}

/// Whether the target carries a URI scheme (RFC 3986 `scheme:`).
pub fn uri_scheme(target: &str) -> Option<&str> {
    let (scheme, _) = target.split_once(':')?;
    let mut chars = scheme.chars();
    let first = chars.next()?;
    (first.is_ascii_alphabetic() && chars.all(|c| c.is_ascii_alphanumeric() || "+-.".contains(c)))
        .then_some(scheme)
}

fn as_file(target: &str) -> Result<String, ExecError> {
    match uri_scheme(target) {
        None => Ok(target.into()),
        Some(scheme) if scheme.eq_ignore_ascii_case("file") => file_uri_to_path(target)
            .map(|path| path.to_string_lossy().into_owned())
            .ok_or_else(|| ExecError::NonLocalFile(target.into())),
        Some(_) => Err(ExecError::NonLocalFile(target.into())),
    }
}

fn as_uri(target: &str) -> String {
    if uri_scheme(target).is_some() {
        return target.into();
    }
    let mut uri = String::from("file://");
    for byte in target.bytes() {
        if byte.is_ascii_alphanumeric() || b"/-._~".contains(&byte) {
            uri.push(byte as char);
        } else {
            uri.push_str(&format!("%{byte:02X}"));
        }
    }
    uri
}

/// `file:///a%20b` → `/a b`; `None` for a remote host.
pub fn file_uri_to_path(uri: &str) -> Option<PathBuf> {
    let rest = uri
        .get(7..)
        .filter(|_| uri[..7].eq_ignore_ascii_case("file://"))?;
    let path = match rest.find('/') {
        Some(0) => rest,
        Some(index) if &rest[..index] == "localhost" => &rest[index..],
        _ => return None,
    };
    let bytes = path.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' && index + 2 < bytes.len() {
            let hex = std::str::from_utf8(&bytes[index + 1..index + 3]).ok()?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            index += 3;
        } else {
            out.push(bytes[index]);
            index += 1;
        }
    }
    use std::os::unix::ffi::OsStringExt;
    Some(PathBuf::from(std::ffi::OsString::from_vec(out)))
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIREFOX: &str = "\
# comment
[Desktop Entry]
Type=Application
Name=Firefox Web Browser
Name[zh_TW]=Firefox 網頁瀏覽器
Name[zh]=Firefox 浏览器
GenericName=Web Browser
GenericName[zh_TW]=網頁瀏覽器
Keywords=Internet;WWW;Browser;
Keywords[zh_TW]=網際網路;瀏覽器;
Exec=firefox %u
Icon=firefox
Categories=Network;WebBrowser;
MimeType=text/html;x-scheme-handler/http;

[Desktop Action new-window]
Name=New Window
Exec=firefox --new-window %u
";

    #[test]
    fn parses_the_main_group_only() {
        let entry = parse(FIREFOX).expect("valid entry");
        assert_eq!(entry.kind, "Application");
        assert_eq!(entry.exec.as_deref(), Some("firefox %u"));
        assert_eq!(entry.categories, ["Network", "WebBrowser"]);
        assert_eq!(entry.mime_types, ["text/html", "x-scheme-handler/http"]);
        assert_eq!(entry.name.default, "Firefox Web Browser");
    }

    #[test]
    fn localized_lookup_follows_the_spec_order() {
        let entry = parse(FIREFOX).expect("valid entry");
        assert_eq!(
            entry.name.get(&Locale::parse("zh_TW.UTF-8")),
            "Firefox 網頁瀏覽器"
        );
        assert_eq!(
            entry.name.get(&Locale::parse("zh_CN.UTF-8")),
            "Firefox 浏览器"
        );
        assert_eq!(
            entry.name.get(&Locale::parse("de_DE")),
            "Firefox Web Browser"
        );
        assert_eq!(
            entry.name.get(&Locale::parse("C.UTF-8")),
            "Firefox Web Browser"
        );
        assert_eq!(
            entry.keywords(&Locale::parse("zh_TW")),
            ["網際網路", "瀏覽器"]
        );
        assert_eq!(
            entry.keywords(&Locale::parse("fr")),
            ["Internet", "WWW", "Browser"]
        );
        let generic = entry.generic_name.expect("generic name");
        assert_eq!(generic.get(&Locale::parse("zh_TW@latin")), "網頁瀏覽器");
    }

    #[test]
    fn rejects_entries_without_type_or_name() {
        assert!(parse("[Desktop Entry]\nName=x\n").is_none());
        assert!(parse("[Desktop Entry]\nType=Application\n").is_none());
        assert!(parse("[Other]\nType=Application\nName=x\n").is_none());
        let hidden = parse("[Desktop Entry]\nType=Application\nHidden=true\n").expect("mask");
        assert!(hidden.hidden);
    }

    #[test]
    fn unescapes_strings_and_lists() {
        let entry = parse("[Desktop Entry]\nType=Application\nName=a\\sb\\\\c\nKeywords=x\\;y;z\n")
            .expect("valid");
        assert_eq!(entry.name.default, "a b\\c");
        assert_eq!(entry.keywords[""], ["x;y", "z"]);
    }

    #[test]
    fn show_in_rules() {
        let entry = parse("[Desktop Entry]\nType=Application\nName=a\nOnlyShowIn=KDE;Ditto;\n")
            .expect("valid");
        assert!(entry.shown_in(&["Wayfire".into(), "Ditto".into()]));
        assert!(!entry.shown_in(&["GNOME".into()]));
        let entry = parse("[Desktop Entry]\nType=Application\nName=a\nNotShowIn=Wayfire;\n")
            .expect("valid");
        assert!(!entry.shown_in(&["Wayfire".into()]));
        assert!(entry.shown_in(&[]));
    }

    #[test]
    fn desktop_ids_replace_directory_separators() {
        let dir = Path::new("/usr/share/applications");
        assert_eq!(
            desktop_id(dir, &dir.join("kde4/kate.desktop")).as_deref(),
            Some("kde4-kate.desktop")
        );
        assert_eq!(
            desktop_id(dir, &dir.join("foot.desktop")).as_deref(),
            Some("foot.desktop")
        );
        assert_eq!(desktop_id(dir, &dir.join("readme.txt")), None);
    }

    fn context(target: Option<&str>) -> ExecContext<'_> {
        ExecContext {
            target,
            icon: Some("kate"),
            translated_name: "Kate 編輯器",
            desktop_file: Some(Path::new("/usr/share/applications/org.kde.kate.desktop")),
        }
    }

    #[test]
    fn field_codes_expand_or_disappear() {
        let exec = |line: &str, target| expand_exec(line, &context(target));
        assert_eq!(exec("firefox %u", None).unwrap(), ["firefox"]);
        assert_eq!(
            exec("firefox %u", Some("https://example.org")).unwrap(),
            ["firefox", "https://example.org"]
        );
        assert_eq!(
            exec("kate -b %U", Some("/tmp/a b.txt")).unwrap(),
            ["kate", "-b", "file:///tmp/a%20b.txt"]
        );
        assert_eq!(
            exec("kate %F", Some("file:///tmp/a%20b.txt")).unwrap(),
            ["kate", "/tmp/a b.txt"]
        );
        assert_eq!(
            exec("app %i %c %k %d %D %n %N %v %m", None).unwrap(),
            [
                "app",
                "--icon",
                "kate",
                "Kate 編輯器",
                "/usr/share/applications/org.kde.kate.desktop"
            ]
        );
        assert_eq!(
            exec("app --file=%f 100%%", Some("/x")).unwrap(),
            ["app", "--file=/x", "100%"]
        );
        assert_eq!(
            exec("app %f", Some("https://example.org")),
            Err(ExecError::NonLocalFile("https://example.org".into()))
        );
    }

    #[test]
    fn quoting_follows_the_exec_rules() {
        let exec = |line: &str| expand_exec(line, &context(None));
        assert_eq!(
            exec(r#"sh -c "echo \"hi\" \$HOME \\ \`x\`""#).unwrap(),
            ["sh", "-c", r#"echo "hi" $HOME \ `x`"#]
        );
        assert_eq!(exec(r#"app "" "a b""#).unwrap(), ["app", "", "a b"]);
        assert_eq!(exec(r#"app "open"#), Err(ExecError::UnterminatedQuote));
        assert_eq!(exec("%u"), Err(ExecError::Empty));
        // In the file `\\\\` is `\\` after string unescaping, then `\` in quotes.
        let entry = parse("[Desktop Entry]\nType=Application\nName=a\nExec=sh -c \"a\\\\\\\\b\"\n")
            .unwrap();
        assert_eq!(
            exec(entry.exec.as_deref().unwrap()).unwrap(),
            ["sh", "-c", "a\\b"]
        );
    }

    #[test]
    fn uri_helpers() {
        assert_eq!(uri_scheme("https://x"), Some("https"));
        assert_eq!(uri_scheme("/tmp/a:b"), None);
        assert_eq!(uri_scheme("mailto:a@b"), Some("mailto"));
        assert_eq!(
            file_uri_to_path("file:///tmp/%E4%B8%AD.txt"),
            Some(PathBuf::from("/tmp/中.txt"))
        );
        assert_eq!(
            file_uri_to_path("file://localhost/etc"),
            Some(PathBuf::from("/etc"))
        );
        assert_eq!(file_uri_to_path("file://server/share"), None);
    }
}

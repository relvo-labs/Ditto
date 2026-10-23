//! The content-addressed package store. A `.dittopkg` is tar+zstd with a
//! `manifest.json` at its root; its sha256 (of the whole file) names the
//! directory it is unpacked into. Unpacking goes to `.staging/<job>/` first
//! and is renamed into place only after every check passes, so a failure in
//! the middle leaves no half-installed package behind.

use std::{
    fs,
    io::Read,
    path::{Path, PathBuf},
    process::Command,
};

use ditto_protocol::{jcs, manifest::Manifest, services::PackageSummary};
use rusqlite::{params, Connection, OptionalExtension, Row};

use crate::{
    error::{StoreError, StoreResult},
    time, Paths,
};

pub const ARCHIVE_NAME: &str = "package.dittopkg";

pub fn sha256_file(path: &Path) -> StoreResult<String> {
    use std::io::BufReader;
    let mut reader = BufReader::new(fs::File::open(path)?);
    let mut bytes = Vec::new();
    reader.read_to_end(&mut bytes)?;
    Ok(jcs::sha256_hex(&bytes))
}

/// A digest of the unpacked tree: sorted relative paths with their contents'
/// sha256. Preflight recomputes it, so a package changed on disk after
/// installation is caught as an integrity mismatch.
pub fn tree_digest(root: &Path) -> StoreResult<String> {
    let mut files = Vec::new();
    collect_files(root, root, &mut files)?;
    files.sort();
    let mut listing = String::new();
    for relative in files {
        if relative == ARCHIVE_NAME {
            continue;
        }
        let digest = sha256_file(&root.join(&relative))?;
        listing.push_str(&relative);
        listing.push('\0');
        listing.push_str(&digest);
        listing.push('\n');
    }
    Ok(jcs::sha256_hex(listing.as_bytes()))
}

fn collect_files(root: &Path, directory: &Path, out: &mut Vec<String>) -> StoreResult<()> {
    for entry in fs::read_dir(directory)? {
        let entry = entry?;
        let kind = entry.file_type()?;
        let path = entry.path();
        if kind.is_symlink() {
            return Err(StoreError::Invalid(format!(
                "package contains a symbolic link: {}",
                path.display()
            )));
        }
        if kind.is_dir() {
            collect_files(root, &path, out)?;
        } else if kind.is_file() {
            let relative = path
                .strip_prefix(root)
                .map_err(|_| StoreError::Invalid("path outside package".into()))?;
            out.push(relative.to_string_lossy().into_owned());
        } else {
            return Err(StoreError::Invalid(format!(
                "package contains a special file: {}",
                path.display()
            )));
        }
    }
    Ok(())
}

#[derive(Clone, Debug)]
pub struct Unpacked {
    pub sha256: String,
    pub tree_sha256: String,
    pub manifest: Manifest,
    pub directory: PathBuf,
    pub already_present: bool,
}

/// Unpack and verify an archive into the store. Does not touch the database;
/// the caller records the package in the same step that makes it visible.
/// `stage` names the staging directory (normally the job id).
pub fn unpack(
    paths: &Paths,
    archive: &Path,
    expected_sha256: Option<&str>,
    stage: &str,
) -> StoreResult<Unpacked> {
    let sha256 = sha256_file(archive)?;
    if let Some(expected) = expected_sha256 {
        if expected.trim_start_matches("sha256:") != sha256 {
            return Err(StoreError::Conflict(format!(
                "package sha256 {sha256} does not match the expected {expected}"
            )));
        }
    }
    let target = paths.package_dir(&sha256);
    if target.join("manifest.json").exists() {
        let manifest = read_manifest(&target)?;
        return Ok(Unpacked {
            tree_sha256: tree_digest(&target)?,
            sha256,
            manifest,
            directory: target,
            already_present: true,
        });
    }
    let staging = paths.staging().join(stage);
    if staging.exists() {
        fs::remove_dir_all(&staging)?;
    }
    fs::create_dir_all(&staging)?;
    let outcome = (|| {
        let status = Command::new("tar")
            .arg("--zstd")
            .arg("-xf")
            .arg(archive)
            .arg("-C")
            .arg(&staging)
            .arg("--no-same-owner")
            .arg("--no-same-permissions")
            .status()?;
        if !status.success() {
            return Err(StoreError::Invalid(
                "the package archive could not be unpacked".into(),
            ));
        }
        crate::fault::during_unpack()?;
        let manifest = read_manifest(&staging)?;
        let problems = manifest.check();
        if !problems.is_empty() {
            return Err(StoreError::Invalid(format!(
                "manifest: {}",
                problems.join("; ")
            )));
        }
        for relative in manifest.entry.iter().chain(manifest.qml_entry.iter()) {
            if !staging.join(relative).is_file() {
                return Err(StoreError::Invalid(format!(
                    "entry file {relative} is missing"
                )));
            }
        }
        let tree_sha256 = tree_digest(&staging)?;
        fs::copy(archive, staging.join(ARCHIVE_NAME))?;
        fs::create_dir_all(target.parent().expect("package dir has a parent"))?;
        // Moving a directory to a new parent needs write permission on it,
        // so it becomes read-only only once it is in place.
        fs::rename(&staging, &target)?;
        make_read_only(&target)?;
        Ok(Unpacked {
            sha256: sha256.clone(),
            tree_sha256,
            manifest,
            directory: target.clone(),
            already_present: false,
        })
    })();
    if outcome.is_err() {
        let _ = make_writable(&staging);
        let _ = fs::remove_dir_all(&staging);
    }
    outcome
}

pub fn read_manifest(directory: &Path) -> StoreResult<Manifest> {
    let text = fs::read_to_string(directory.join("manifest.json"))
        .map_err(|_| StoreError::Invalid("manifest.json is missing".into()))?;
    Ok(serde_json::from_str(&text)?)
}

fn make_read_only(directory: &Path) -> StoreResult<()> {
    set_tree_mode(directory, 0o500, 0o400)
}

pub fn make_writable(directory: &Path) -> StoreResult<()> {
    set_tree_mode(directory, 0o700, 0o600)
}

fn set_tree_mode(directory: &Path, dir_mode: u32, file_mode: u32) -> StoreResult<()> {
    use std::os::unix::fs::PermissionsExt;
    if !directory.exists() {
        return Ok(());
    }
    fs::set_permissions(directory, fs::Permissions::from_mode(0o700))?;
    for entry in fs::read_dir(directory)? {
        let entry = entry?;
        let path = entry.path();
        if entry.file_type()?.is_dir() {
            set_tree_mode(&path, dir_mode, file_mode)?;
        } else if entry.file_type()?.is_file() {
            fs::set_permissions(&path, fs::Permissions::from_mode(file_mode))?;
        }
    }
    fs::set_permissions(directory, fs::Permissions::from_mode(dir_mode))?;
    Ok(())
}

pub fn remove_directory(paths: &Paths, sha256: &str) -> StoreResult<()> {
    let target = paths.package_dir(sha256);
    make_writable(&target)?;
    if target.exists() {
        fs::remove_dir_all(target)?;
    }
    Ok(())
}

// ---- index ------------------------------------------------------------------

#[derive(Clone, Debug)]
pub struct PackageRow {
    pub summary: PackageSummary,
    pub tree_sha256: String,
    pub manifest: Manifest,
    pub generated: Option<ditto_protocol::generation::GeneratedArtifact>,
}

const COLUMNS: &str =
    "package_id, version, sha256, tree_sha256, source, manifest_json, installed_at";

fn row(
    row: &Row<'_>,
) -> rusqlite::Result<(String, String, String, String, String, String, String)> {
    Ok((
        row.get(0)?,
        row.get(1)?,
        row.get(2)?,
        row.get(3)?,
        row.get(4)?,
        row.get(5)?,
        row.get(6)?,
    ))
}

fn build(
    connection: &Connection,
    raw: (String, String, String, String, String, String, String),
) -> StoreResult<PackageRow> {
    let (package_id, version, sha256, tree_sha256, source, manifest_json, installed_at) = raw;
    let manifest: Manifest = serde_json::from_str(&manifest_json)?;
    let referenced_by = references(connection, &package_id, &version)?;
    Ok(PackageRow {
        generated: if source == "generated" {
            crate::generated::by_package(connection, &package_id, &version)?
        } else {
            None
        },
        summary: PackageSummary {
            package_id,
            version,
            sha256,
            source,
            name: manifest.name.clone(),
            author: manifest.author.clone(),
            license: manifest.license.clone(),
            plugin_kind: manifest.plugin_kind,
            host_kind: manifest.host_kind,
            trust_level: manifest.trust_level,
            installed_at,
            referenced_by,
        },
        tree_sha256,
        manifest,
    })
}

pub fn insert(
    connection: &Connection,
    unpacked: &Unpacked,
    source: &str,
    job_id: Option<&str>,
) -> StoreResult<PackageRow> {
    if let Some(existing) = get(
        connection,
        &unpacked.manifest.id,
        &unpacked.manifest.version,
    )? {
        if existing.summary.sha256 != unpacked.sha256 {
            return Err(StoreError::Conflict(format!(
                "{} {} is already installed with different content",
                unpacked.manifest.id, unpacked.manifest.version
            )));
        }
        return Ok(existing);
    }
    connection.execute(
        "INSERT INTO plugin_packages (package_id, version, sha256, tree_sha256, source, manifest_json, installed_at, installed_by_job)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
        params![
            unpacked.manifest.id,
            unpacked.manifest.version,
            unpacked.sha256,
            unpacked.tree_sha256,
            source,
            serde_json::to_string(&unpacked.manifest)?,
            time::now(),
            job_id
        ],
    )?;
    get(
        connection,
        &unpacked.manifest.id,
        &unpacked.manifest.version,
    )?
    .ok_or_else(|| StoreError::NotFound("package just inserted".into()))
}

pub fn get(
    connection: &Connection,
    package_id: &str,
    version: &str,
) -> StoreResult<Option<PackageRow>> {
    let raw = connection
        .query_row(
            &format!(
                "SELECT {COLUMNS} FROM plugin_packages WHERE package_id = ?1 AND version = ?2"
            ),
            params![package_id, version],
            row,
        )
        .optional()?;
    raw.map(|raw| build(connection, raw)).transpose()
}

pub fn versions(connection: &Connection, package_id: &str) -> StoreResult<Vec<String>> {
    let mut statement = connection.prepare(
        "SELECT version FROM plugin_packages WHERE package_id = ?1 ORDER BY installed_at",
    )?;
    let rows = statement.query_map([package_id], |row| row.get(0))?;
    Ok(rows.collect::<Result<_, _>>()?)
}

pub fn list(connection: &Connection) -> StoreResult<Vec<PackageRow>> {
    let mut statement = connection.prepare(&format!(
        "SELECT {COLUMNS} FROM plugin_packages ORDER BY package_id, version"
    ))?;
    let raws: Vec<_> = statement.query_map([], row)?.collect::<Result<_, _>>()?;
    raws.into_iter().map(|raw| build(connection, raw)).collect()
}

/// Retained revisions that pin this package version.
pub fn references(connection: &Connection, package_id: &str, version: &str) -> StoreResult<u32> {
    Ok(connection.query_row(
        "SELECT COUNT(DISTINCT profile_revision) FROM plugin_instances WHERE package_id = ?1 AND version = ?2",
        params![package_id, version],
        |row| row.get(0),
    )?)
}

/// Remove an unreferenced package. Returns its sha256 so the caller can
/// delete the directory after the row is gone.
pub fn remove(connection: &Connection, package_id: &str, version: &str) -> StoreResult<String> {
    let package = get(connection, package_id, version)?
        .ok_or_else(|| StoreError::NotFound(format!("package {package_id} {version}")))?;
    if package.summary.referenced_by > 0 {
        return Err(StoreError::Conflict(format!(
            "{package_id} {version} is used by {} retained revisions",
            package.summary.referenced_by
        )));
    }
    connection.execute(
        "DELETE FROM plugin_packages WHERE package_id = ?1 AND version = ?2",
        params![package_id, version],
    )?;
    Ok(package.summary.sha256)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing;

    pub fn build_archive(
        root: &Path,
        manifest: &serde_json::Value,
        files: &[(&str, &str)],
    ) -> PathBuf {
        let source = root.join(format!("src-{}", ditto_protocol::ids::ulid()));
        fs::create_dir_all(&source).unwrap();
        fs::write(
            source.join("manifest.json"),
            serde_json::to_string_pretty(manifest).unwrap(),
        )
        .unwrap();
        for (path, text) in files {
            let file = source.join(path);
            fs::create_dir_all(file.parent().unwrap()).unwrap();
            fs::write(file, text).unwrap();
        }
        let archive = root.join(format!("{}.dittopkg", ditto_protocol::ids::ulid()));
        let status = Command::new("tar")
            .arg("--zstd")
            .arg("-cf")
            .arg(&archive)
            .arg("-C")
            .arg(&source)
            .arg(".")
            .status()
            .unwrap();
        assert!(status.success());
        archive
    }

    pub fn manifest(id: &str) -> serde_json::Value {
        serde_json::json!({
            "manifest_version": 1, "id": id, "version": "1.0.0", "name": "Test", "author": "Ditto",
            "license": "UNLICENSED", "source": "builtin", "plugin_kind": "qml_provider", "host_kind": "qml",
            "trust_level": "trusted", "required_protocol_version": "^0.2", "slots": ["ui.dock"],
            "qml_entry": "qml/Dock.qml", "hot_swap": "instant", "health": {"timeout_ms": 2000},
            "cleanup": {"timeout_ms": 2000}, "idle_policy": "resident"
        })
    }

    #[test]
    fn installs_verifies_and_detects_tampering() {
        let mut temp = testing::open("packages");
        let archive = build_archive(
            &temp.root,
            &manifest("ditto.test.dock"),
            &[("qml/Dock.qml", "Item {}")],
        );
        let paths = temp.store.paths().clone();
        let unpacked = unpack(&paths, &archive, None, "job-1").unwrap();
        assert!(!unpacked.already_present);
        let row = temp
            .store
            .write(|tx| insert(tx, &unpacked, "builtin", None))
            .unwrap();
        assert_eq!(row.summary.sha256, sha256_file(&archive).unwrap());
        assert_eq!(tree_digest(&unpacked.directory).unwrap(), row.tree_sha256);
        // Tampering with the unpacked tree changes the digest.
        make_writable(&unpacked.directory).unwrap();
        fs::write(unpacked.directory.join("qml/Dock.qml"), "Item { id: evil }").unwrap();
        assert_ne!(tree_digest(&unpacked.directory).unwrap(), row.tree_sha256);
    }

    /// #161 repair 2: a complete tree already in the content store but not
    /// indexed (an install interrupted before the subset check existed) is
    /// checked like a fresh install before anything indexes it.
    #[test]
    fn a_cached_tree_with_an_unsupported_config_schema_is_refused_like_a_fresh_install() {
        let mut temp = testing::open("package-cached-schema");
        let paths = temp.store.paths().clone();
        let mut bad = manifest("ditto.test.cached");
        bad["config_schema"] = serde_json::json!({"type": "object", "properties": {"x": 3}});
        let archive = build_archive(&temp.root, &bad, &[("qml/Dock.qml", "Item {}")]);
        let fresh = match unpack(&paths, &archive, None, "job-fresh") {
            Err(StoreError::Invalid(message)) => message,
            other => panic!("a fresh install must refuse it: {other:?}"),
        };
        assert!(fresh.contains("config_schema/properties/x"), "{fresh}");
        // The tree an older Core left behind, complete but never indexed.
        let cached = paths.package_dir(&sha256_file(&archive).unwrap());
        fs::create_dir_all(&cached).unwrap();
        let status = Command::new("tar")
            .arg("--zstd")
            .arg("-xf")
            .arg(&archive)
            .arg("-C")
            .arg(&cached)
            .status()
            .unwrap();
        assert!(status.success());
        assert!(cached.join("manifest.json").is_file());
        match unpack(&paths, &archive, None, "job-cached") {
            Err(StoreError::Invalid(message)) => assert_eq!(message, fresh),
            other => panic!("the cached tree must be refused the same way: {other:?}"),
        }
        assert!(list(temp.store.connection()).unwrap().is_empty());

        // A package indexed before the check keeps its row: reinstalling it
        // is refused, but nothing is removed from the index.
        let legacy = Unpacked {
            sha256: sha256_file(&archive).unwrap(),
            tree_sha256: tree_digest(&cached).unwrap(),
            manifest: serde_json::from_value(bad).unwrap(),
            directory: cached.clone(),
            already_present: true,
        };
        temp.store
            .write(|tx| insert(tx, &legacy, "builtin", None))
            .unwrap();
        assert!(unpack(&paths, &archive, None, "job-again").is_err());
        assert!(get(temp.store.connection(), "ditto.test.cached", "1.0.0")
            .unwrap()
            .is_some());
    }

    #[test]
    fn a_hash_mismatch_or_a_bad_manifest_leaves_no_half_package() {
        let temp = testing::open("package-fail");
        let paths = temp.store.paths().clone();
        let archive = build_archive(
            &temp.root,
            &manifest("ditto.test.dock"),
            &[("qml/Dock.qml", "Item {}")],
        );
        assert!(matches!(
            unpack(&paths, &archive, Some("sha256:00"), "job-2"),
            Err(StoreError::Conflict(_))
        ));
        let broken = build_archive(&temp.root, &manifest("ditto.test.dock"), &[]);
        assert!(unpack(&paths, &broken, None, "job-3").is_err());
        assert!(!paths.staging().join("job-3").exists());
        let installed = paths.packages().join("sha256");
        let count = fs::read_dir(&installed).map(|dir| dir.count()).unwrap_or(0);
        assert_eq!(count, 0, "nothing reached the package store");
    }
}

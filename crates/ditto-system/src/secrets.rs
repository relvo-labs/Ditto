//! Secret Service (org.freedesktop.secrets) for model API keys (G2-CORE-04).
//! Core keeps only an opaque reference; the value lives in the person's
//! keyring. A locked or prompting collection is refused (`Locked`), never
//! worked around, and there is no file or environment fallback.
#![cfg(feature = "dbus")]

use std::collections::HashMap;

use zbus::blocking::{Connection, Proxy};
use zbus::zvariant::{ObjectPath, OwnedObjectPath, OwnedValue, Value};

const SERVICE: &str = "org.freedesktop.secrets";
const SERVICE_PATH: &str = "/org/freedesktop/secrets";
const DEFAULT_COLLECTION: &str = "/org/freedesktop/secrets/aliases/default";
/// Every Ditto item carries this attribute, and lookups always include it,
/// so Ditto never reads or deletes another application's secrets.
const APPLICATION: &str = "ditto";

#[derive(Debug, PartialEq, Eq)]
pub enum SecretError {
    /// No Secret Service on the session bus.
    Unavailable,
    /// The keyring is locked or would need a prompt.
    Locked,
    /// No item for that reference.
    Missing,
    Failed(String),
}

type Secret = (OwnedObjectPath, Vec<u8>, Vec<u8>, String);

pub struct SecretStore {
    connection: Connection,
}

fn failed(error: impl std::fmt::Display) -> SecretError {
    SecretError::Failed(error.to_string())
}

impl SecretStore {
    pub fn connect() -> Result<Self, SecretError> {
        let connection = Connection::session().map_err(|_| SecretError::Unavailable)?;
        let dbus = zbus::blocking::fdo::DBusProxy::new(&connection)
            .map_err(|_| SecretError::Unavailable)?;
        let name = zbus::names::BusName::try_from(SERVICE).map_err(failed)?;
        // Activatable is enough: gnome-keyring and KWallet start on demand.
        let present = dbus.name_has_owner(name.clone()).unwrap_or(false)
            || dbus
                .list_activatable_names()
                .map(|names| names.iter().any(|n| n.as_str() == SERVICE))
                .unwrap_or(false);
        if !present {
            return Err(SecretError::Unavailable);
        }
        Ok(Self { connection })
    }

    fn service(&self) -> Result<Proxy<'_>, SecretError> {
        Proxy::new(
            &self.connection,
            SERVICE,
            SERVICE_PATH,
            "org.freedesktop.Secret.Service",
        )
        .map_err(failed)
    }

    fn session(&self) -> Result<OwnedObjectPath, SecretError> {
        let (_, session): (OwnedValue, OwnedObjectPath) = self
            .service()?
            .call("OpenSession", &("plain", Value::from("")))
            .map_err(|_| SecretError::Unavailable)?;
        Ok(session)
    }

    fn attributes(reference: &str) -> HashMap<&str, &str> {
        HashMap::from([
            ("application", APPLICATION),
            ("ditto_credential", reference),
        ])
    }

    /// Store `secret` under `reference`, replacing an existing value.
    pub fn store(&self, reference: &str, label: &str, secret: &[u8]) -> Result<(), SecretError> {
        let session = self.session()?;
        let collection = Proxy::new(
            &self.connection,
            SERVICE,
            DEFAULT_COLLECTION,
            "org.freedesktop.Secret.Collection",
        )
        .map_err(failed)?;
        let locked: bool = collection.get_property("Locked").unwrap_or(true);
        if locked {
            return Err(SecretError::Locked);
        }
        let mut properties: HashMap<&str, Value> = HashMap::new();
        properties.insert("org.freedesktop.Secret.Item.Label", Value::from(label));
        properties.insert(
            "org.freedesktop.Secret.Item.Attributes",
            Value::from(Self::attributes(reference)),
        );
        let value: (ObjectPath, &[u8], &[u8], &str) = (session.as_ref(), &[], secret, "text/plain");
        let (_item, prompt): (OwnedObjectPath, OwnedObjectPath) = collection
            .call("CreateItem", &(properties, value, true))
            .map_err(failed)?;
        if prompt.as_str() != "/" {
            // A prompt means the person would have to unlock or confirm in
            // another dialog; Ditto does not drive that on their behalf.
            let _ = Proxy::new(
                &self.connection,
                SERVICE,
                prompt.as_str(),
                "org.freedesktop.Secret.Prompt",
            )
            .and_then(|p| p.call_method("Dismiss", &()).map(|_| ()));
            return Err(SecretError::Locked);
        }
        Ok(())
    }

    fn item(&self, reference: &str) -> Result<OwnedObjectPath, SecretError> {
        let (unlocked, locked): (Vec<OwnedObjectPath>, Vec<OwnedObjectPath>) = self
            .service()?
            .call("SearchItems", &(Self::attributes(reference),))
            .map_err(failed)?;
        if let Some(item) = unlocked.into_iter().next() {
            return Ok(item);
        }
        if !locked.is_empty() {
            return Err(SecretError::Locked);
        }
        Err(SecretError::Missing)
    }

    pub fn lookup(&self, reference: &str) -> Result<Vec<u8>, SecretError> {
        let item = self.item(reference)?;
        let session = self.session()?;
        let proxy = Proxy::new(
            &self.connection,
            SERVICE,
            item.as_str(),
            "org.freedesktop.Secret.Item",
        )
        .map_err(failed)?;
        let secret: Secret = proxy.call("GetSecret", &(session,)).map_err(failed)?;
        Ok(secret.2)
    }

    pub fn exists(&self, reference: &str) -> Result<bool, SecretError> {
        match self.item(reference) {
            Ok(_) => Ok(true),
            Err(SecretError::Missing) => Ok(false),
            Err(error) => Err(error),
        }
    }

    pub fn delete(&self, reference: &str) -> Result<(), SecretError> {
        let item = match self.item(reference) {
            Ok(item) => item,
            Err(SecretError::Missing) => return Ok(()),
            Err(error) => return Err(error),
        };
        let proxy = Proxy::new(
            &self.connection,
            SERVICE,
            item.as_str(),
            "org.freedesktop.Secret.Item",
        )
        .map_err(failed)?;
        let prompt: OwnedObjectPath = proxy.call("Delete", &()).map_err(failed)?;
        if prompt.as_str() != "/" {
            return Err(SecretError::Locked);
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Runs against the session's real Secret Service when there is one
    /// (and its default collection is unlocked); skipped otherwise.
    #[test]
    fn store_lookup_replace_and_delete_one_ditto_item() {
        let Ok(store) = SecretStore::connect() else {
            eprintln!("no Secret Service; skipped");
            return;
        };
        let reference = format!("cred-test-{}", std::process::id());
        match store.store(&reference, "Ditto test credential", b"first-canary") {
            Err(SecretError::Locked) => {
                eprintln!("keyring locked; skipped");
                return;
            }
            other => other.unwrap(),
        }
        assert_eq!(store.lookup(&reference).unwrap(), b"first-canary");
        store
            .store(&reference, "Ditto test credential", b"second-canary")
            .unwrap();
        assert_eq!(store.lookup(&reference).unwrap(), b"second-canary");
        assert!(store.exists(&reference).unwrap());
        store.delete(&reference).unwrap();
        assert_eq!(store.lookup(&reference), Err(SecretError::Missing));
        assert!(!store.exists(&reference).unwrap());
        // Deleting what is not there is not an error.
        store.delete(&reference).unwrap();
    }
}

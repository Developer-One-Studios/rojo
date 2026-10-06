//! Content fingerprints for instances in a serve session's tree.
//!
//! When several people sync into the same Team Create place, each of them runs
//! their own `rojo serve`. Instance IDs are only meaningful within a single
//! server, so the plugin can't use them to compare one person's files against
//! what a teammate synced earlier. A fingerprint depends only on an instance's
//! name, class and properties, so two servers serving the same file produce
//! the same fingerprint, and the plugin can tell whether the version in the
//! place came from files identical to its own.

use blake3::Hasher;
use rbx_dom_weak::{
    types::{ContentType, Variant},
    Ustr,
};

/// How many bytes of the BLAKE3 digest to keep. 64 bits is plenty to tell
/// revisions of a single instance apart, and keeps the record the plugin
/// stores in the place small.
const FINGERPRINT_BYTES: usize = 8;

/// Computes the fingerprint of an instance from its name, class and properties.
///
/// The plugin keys fingerprints by path, which already contains the name, but
/// renames can happen without the path changing in the plugin's eyes (the
/// plugin finds an instance's path by where it is now). Including the name
/// means renaming something differently than a teammate still shows up.
pub fn fingerprint<'a>(
    name: &str,
    class_name: &str,
    properties: impl IntoIterator<Item = (&'a Ustr, &'a Variant)>,
) -> String {
    let mut properties: Vec<_> = properties
        .into_iter()
        .filter(|(_, value)| is_portable(value))
        .collect();

    // Property maps are unordered, but the fingerprint must not depend on
    // the order properties happened to be inserted in.
    properties.sort_unstable_by(|(a, _), (b, _)| a.as_str().cmp(b.as_str()));

    let mut hasher = Hasher::new();
    hasher.update(&(name.len() as u64).to_le_bytes());
    hasher.update(name.as_bytes());
    hasher.update(&(class_name.len() as u64).to_le_bytes());
    hasher.update(class_name.as_bytes());

    for (name, value) in properties {
        // Length-prefix each field so that adjacent fields can never run
        // together into the same byte sequence.
        let encoded = encode_value(value);
        hasher.update(&(name.len() as u64).to_le_bytes());
        hasher.update(name.as_bytes());
        hasher.update(&(encoded.len() as u64).to_le_bytes());
        hasher.update(&encoded);
    }

    data_encoding::HEXLOWER.encode(&hasher.finalize().as_bytes()[..FINGERPRINT_BYTES])
}

/// Whether a value means the same thing on every machine serving the project.
fn is_portable(value: &Variant) -> bool {
    match value {
        // Referents are allocated per server session, so the same file gets a
        // different value on every teammate's machine.
        Variant::Ref(_) | Variant::UniqueId(_) => false,
        Variant::Content(content) => {
            matches!(content.value(), ContentType::None | ContentType::Uri(_))
        }
        _ => true,
    }
}

/// Encodes a value exactly. Unlike the syncback hashes, floats are not rounded:
/// both sides parse the same files, so identical content always produces
/// identical bits, and rounding would hide small but real edits.
fn encode_value(value: &Variant) -> Vec<u8> {
    match value {
        // SharedStrings can't be serialized through serde, but they carry their
        // own content hash.
        Variant::SharedString(shared) => shared.hash().as_bytes().to_vec(),
        // Git can check the same file out with different line endings on
        // different operating systems, and Rojo keeps whichever it finds. A
        // teammate on another OS has the same content, so it must match.
        Variant::String(string) if string.contains("\r\n") => {
            let normalized = Variant::String(string.replace("\r\n", "\n"));
            encode_value(&normalized)
        }
        other => rmp_serde::to_vec(other).unwrap_or_else(|err| {
            log::warn!(
                "Could not encode {:?} for fingerprinting: {}",
                other.ty(),
                err
            );
            format!("{:?}", other.ty()).into_bytes()
        }),
    }
}

#[cfg(test)]
mod test {
    use super::*;

    use rbx_dom_weak::{
        types::{Ref, Vector3},
        ustr, UstrMap,
    };

    fn props(entries: &[(&str, Variant)]) -> UstrMap<Variant> {
        entries
            .iter()
            .map(|(name, value)| (ustr(name), value.clone()))
            .collect()
    }

    #[test]
    fn same_content_same_fingerprint() {
        let a = props(&[
            ("Source", Variant::String("print('hi')".into())),
            ("Disabled", Variant::Bool(false)),
        ]);
        let b = props(&[
            ("Disabled", Variant::Bool(false)),
            ("Source", Variant::String("print('hi')".into())),
        ]);

        assert_eq!(
            fingerprint("Util", "Script", &a),
            fingerprint("Util", "Script", &b)
        );
        assert_eq!(
            fingerprint("Util", "Script", &a).len(),
            FINGERPRINT_BYTES * 2
        );
    }

    #[test]
    fn different_content_different_fingerprint() {
        let a = props(&[("Source", Variant::String("print('hi')".into()))]);
        let b = props(&[("Source", Variant::String("print('bye')".into()))]);

        assert_ne!(
            fingerprint("Util", "Script", &a),
            fingerprint("Util", "Script", &b)
        );
    }

    #[test]
    fn class_name_is_part_of_fingerprint() {
        let a = props(&[("Source", Variant::String("return {}".into()))]);

        assert_ne!(
            fingerprint("Util", "ModuleScript", &a),
            fingerprint("Util", "LocalScript", &a)
        );
    }

    #[test]
    fn name_is_part_of_fingerprint() {
        let a = props(&[("Source", Variant::String("return {}".into()))]);

        assert_ne!(
            fingerprint("Old", "ModuleScript", &a),
            fingerprint("New", "ModuleScript", &a)
        );
    }

    #[test]
    fn line_endings_are_ignored() {
        let lf = props(&[("Source", Variant::String("local a = 1\nreturn a\n".into()))]);
        let crlf = props(&[(
            "Source",
            Variant::String("local a = 1\r\nreturn a\r\n".into()),
        )]);

        assert_eq!(
            fingerprint("Util", "ModuleScript", &lf),
            fingerprint("Util", "ModuleScript", &crlf)
        );
    }

    #[test]
    fn small_float_changes_are_detected() {
        let a = props(&[("Size", Variant::Vector3(Vector3::new(1.0, 1.0, 1.0)))]);
        let b = props(&[("Size", Variant::Vector3(Vector3::new(1.01, 1.0, 1.0)))]);

        assert_ne!(
            fingerprint("Part", "Part", &a),
            fingerprint("Part", "Part", &b)
        );
    }

    #[test]
    fn referents_are_ignored() {
        let a = props(&[
            ("Value", Variant::Ref(Ref::new())),
            ("Name2", Variant::String("x".into())),
        ]);
        let b = props(&[
            ("Value", Variant::Ref(Ref::new())),
            ("Name2", Variant::String("x".into())),
        ]);

        assert_eq!(
            fingerprint("Value", "ObjectValue", &a),
            fingerprint("Value", "ObjectValue", &b)
        );
    }

    #[test]
    fn fields_cannot_run_together() {
        let a = props(&[
            ("A", Variant::String("BC".into())),
            ("D", Variant::String("".into())),
        ]);
        let b = props(&[
            ("A", Variant::String("B".into())),
            ("D", Variant::String("C".into())),
        ]);

        assert_ne!(
            fingerprint("Folder", "Folder", &a),
            fingerprint("Folder", "Folder", &b)
        );
    }
}

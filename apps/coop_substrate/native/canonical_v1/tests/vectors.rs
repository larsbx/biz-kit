//! BEAM-independent verification of the committed test vectors
//! (test/vectors/canonical_v1_vectors.json) against the pure-Rust core
//! encoder: canonical bytes, SHA-256, and Ed25519 signatures.
//!
//! A failure here means the CoopEventCanonicalV1 profile changed — that is a
//! governance event, not a bug fix. Do not regenerate the vectors to make
//! this pass (see scripts/gen_vectors.exs).

use canonical_v1::core::{encode, Value};
use ed25519_dalek::{Signature, Verifier, VerifyingKey};
use serde_json::Value as Json;
use sha2::{Digest, Sha256};

/// Inverse of the JSON term representation in scripts/gen_vectors.exs:
/// {"__bytes__": hex} is a byte string, every other JSON shape is literal.
fn from_json(j: &Json) -> Value {
    match j {
        Json::Null => Value::Null,
        Json::Bool(b) => Value::Bool(*b),
        Json::Number(n) => Value::Int(n.as_i64().expect("vector int fits i64")),
        Json::String(s) => Value::Text(s.clone()),
        Json::Array(items) => Value::List(items.iter().map(from_json).collect()),
        Json::Object(fields) => {
            if fields.len() == 1 {
                if let Some(Json::String(hex)) = fields.get("__bytes__") {
                    return Value::Bytes(hex::decode(hex).expect("valid hex in __bytes__"));
                }
            }
            Value::Map(
                fields
                    .iter()
                    .map(|(k, v)| (k.clone(), from_json(v)))
                    .collect(),
            )
        }
    }
}

#[test]
fn committed_vectors_lock_the_profile() {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../test/vectors/canonical_v1_vectors.json"
    );
    let doc: Json = serde_json::from_str(&std::fs::read_to_string(path).expect("vectors file"))
        .expect("valid JSON");

    assert_eq!(doc["profile"], "CoopEventCanonicalV1");

    let pub_bytes: [u8; 32] = hex::decode(doc["ed25519_pubkey_hex"].as_str().unwrap())
        .unwrap()
        .try_into()
        .unwrap();
    let pubkey = VerifyingKey::from_bytes(&pub_bytes).expect("valid Ed25519 pubkey");

    let vectors = doc["vectors"].as_array().expect("vectors array");
    assert_eq!(vectors.len(), 6, "unexpected vector count");

    for v in vectors {
        let name = v["name"].as_str().unwrap();
        let term = from_json(&v["term"]);
        let expected = hex::decode(v["canonical_hex"].as_str().unwrap()).unwrap();

        let bytes = encode(&term).unwrap_or_else(|e| panic!("{name}: encode failed: {e:?}"));
        assert_eq!(
            hex::encode(&bytes),
            v["canonical_hex"].as_str().unwrap(),
            "{name}: canonical bytes mismatch"
        );

        let digest = Sha256::digest(&expected);
        assert_eq!(
            hex::encode(digest),
            v["sha256_hex"].as_str().unwrap(),
            "{name}: sha256 mismatch"
        );

        let sig_bytes: [u8; 64] = hex::decode(v["sig_hex"].as_str().unwrap())
            .unwrap()
            .try_into()
            .unwrap();
        let sig = Signature::from_bytes(&sig_bytes);
        pubkey
            .verify(&expected, &sig)
            .unwrap_or_else(|e| panic!("{name}: signature invalid: {e}"));
    }
}

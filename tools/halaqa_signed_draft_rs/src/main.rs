//! Offline, non-authoritative decoder/verifier of the proposed signed profile.
//! Uses RustCrypto/dalek, not Python, Elixir, OpenSSL or an Iroh runtime.
use base64::{Engine, engine::general_purpose::STANDARD};
use ed25519_dalek::{Signature, VerifyingKey};
use serde::de::{self, Deserialize, Deserializer, MapAccess, SeqAccess, Visitor};
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use std::{collections::HashSet, fmt, fs::File, io::Read, path::Path};

type Code = &'static str;
const MAX_INTEGER: u64 = (1 << 53) - 1;
const DOMAIN: &[u8] = b"halaqa.federation.signed-experiment/draft-2\0";
const VERDICT: &str = "SIGNATURE_VALID_AUTHORITY_UNVERIFIED";

struct Unique(Value);
struct UniqueVisitor;

impl<'de> Deserialize<'de> for Unique {
    fn deserialize<D: Deserializer<'de>>(decoder: D) -> Result<Self, D::Error> {
        decoder.deserialize_any(UniqueVisitor)
    }
}

impl<'de> Visitor<'de> for UniqueVisitor {
    type Value = Unique;
    fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
        f.write_str("JSON with unique object keys")
    }
    fn visit_bool<E: de::Error>(self, v: bool) -> Result<Unique, E> {
        Ok(Unique(Value::Bool(v)))
    }
    fn visit_i64<E: de::Error>(self, v: i64) -> Result<Unique, E> {
        Ok(Unique(v.into()))
    }
    fn visit_u64<E: de::Error>(self, v: u64) -> Result<Unique, E> {
        Ok(Unique(v.into()))
    }
    fn visit_f64<E: de::Error>(self, v: f64) -> Result<Unique, E> {
        serde_json::Number::from_f64(v)
            .map(|n| Unique(Value::Number(n)))
            .ok_or_else(|| E::custom("invalid_json"))
    }
    fn visit_str<E: de::Error>(self, v: &str) -> Result<Unique, E> {
        Ok(Unique(Value::String(v.to_owned())))
    }
    fn visit_string<E: de::Error>(self, v: String) -> Result<Unique, E> {
        Ok(Unique(Value::String(v)))
    }
    fn visit_unit<E: de::Error>(self) -> Result<Unique, E> {
        Ok(Unique(Value::Null))
    }
    fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<Unique, A::Error> {
        let mut values = Vec::new();
        while let Some(Unique(v)) = seq.next_element()? {
            values.push(v);
        }
        Ok(Unique(Value::Array(values)))
    }
    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Unique, A::Error> {
        let mut values = Map::new();
        while let Some((k, Unique(v))) = map.next_entry::<String, Unique>()? {
            if values.insert(k, v).is_some() {
                return Err(de::Error::custom("duplicate_key"));
            }
        }
        Ok(Unique(Value::Object(values)))
    }
}

fn require(value: bool, code: Code) -> Result<(), Code> {
    if value { Ok(()) } else { Err(code) }
}

fn decode(bytes: &[u8]) -> Result<Value, Code> {
    let (mut depth, mut quoted, mut escaped) = (0_i32, false, false);
    for &b in bytes {
        if quoted {
            if escaped {
                escaped = false;
            } else if b == b'\\' {
                escaped = true;
            } else if b == b'"' {
                quoted = false;
            }
        } else if b == b'"' {
            quoted = true;
        } else if b == b'{' || b == b'[' {
            depth += 1;
        } else if b == b'}' || b == b']' {
            depth -= 1;
        }
        require((0..=8).contains(&depth), "invalid_json")?;
    }
    require(depth == 0 && !quoted, "invalid_json")?;
    serde_json::from_slice::<Unique>(bytes)
        .map(|u| u.0)
        .map_err(|e| {
            if e.to_string().starts_with("duplicate_key at line ") {
                "duplicate_key"
            } else {
                "invalid_json"
            }
        })
}

fn fields<'a>(value: &'a Value, keys: &[&str], code: Code) -> Result<&'a Map<String, Value>, Code> {
    let map = value.as_object().ok_or(code)?;
    require(
        map.len() == keys.len() && keys.iter().all(|k| map.contains_key(*k)),
        code,
    )?;
    Ok(map)
}

fn token(v: &Value) -> bool {
    v.as_str().is_some_and(|s| {
        let b = s.as_bytes();
        !b.is_empty()
            && b.len() <= 128
            && b[0].is_ascii_alphanumeric()
            && b.iter()
                .all(|c| c.is_ascii_alphanumeric() || b"._:-".contains(c))
    })
}

fn digest(v: &Value) -> bool {
    v.as_str().is_some_and(|s| {
        s.len() == 71
            && s.starts_with("sha256:")
            && s.as_bytes()[7..]
                .iter()
                .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(c))
    })
}

fn uint(v: &Value, code: Code) -> Result<u64, Code> {
    v.as_u64().filter(|n| *n <= MAX_INTEGER).ok_or(code)
}

fn base64(v: &Value, code: Code, size: Option<usize>) -> Result<Vec<u8>, Code> {
    let text = v.as_str().ok_or(code)?;
    let bytes = STANDARD.decode(text).map_err(|_| code)?;
    require(
        STANDARD.encode(&bytes) == text && size.is_none_or(|n| bytes.len() == n),
        code,
    )?;
    Ok(bytes)
}

fn candidate(bytes: &[u8]) -> Result<(Map<String, Value>, Vec<u8>), Code> {
    require((1..=8192).contains(&bytes.len()), "wire_limit")?;
    let value = decode(bytes)?;
    let m = fields(
        &value,
        &[
            "schema",
            "message_id",
            "halaqa_id",
            "charter_hash",
            "epoch",
            "sender",
            "recipient",
            "kind",
            "parents",
            "payload",
            "payload_hash",
        ],
        "fields",
    )?;
    require(
        m["schema"] == "halaqa-federation-candidate/draft-0",
        "schema",
    )?;
    require(
        ["message_id", "halaqa_id", "sender", "recipient"]
            .iter()
            .all(|k| token(&m[*k])),
        "identifier",
    )?;
    require(
        digest(&m["charter_hash"]) && digest(&m["payload_hash"]),
        "digest_format",
    )?;
    uint(&m["epoch"], "epoch")?;
    require(
        m["kind"] == "proposal" || m["kind"] == "public_activity",
        "kind",
    )?;
    let parents = m["parents"].as_array().ok_or("parents")?;
    require(parents.len() <= 16 && parents.iter().all(digest), "parents")?;
    let parent_strings: Vec<_> = parents
        .iter()
        .map(|p| p.as_str().expect("digest checked"))
        .collect();
    require(parent_strings.windows(2).all(|w| w[0] < w[1]), "parents")?;
    let payload = base64(&m["payload"], "payload_encoding", None)?;
    require((1..=4096).contains(&payload.len()), "payload_limit")?;
    require(
        m["payload_hash"] == format!("sha256:{:x}", Sha256::digest(&payload)),
        "payload_digest",
    )?;
    Ok((m.clone(), payload))
}

struct Verified {
    payload: Vec<u8>,
    transcript: Vec<u8>,
}

fn point_encoding_allowed(bytes: &[u8]) -> bool {
    let Ok(point) = <[u8; 32]>::try_from(bytes) else {
        return false;
    };
    let mut y = point;
    y[31] &= 0x7f;
    let mut prime = [0xff; 32];
    prime[0] = 0xed;
    prime[31] = 0x7f;
    y.iter().rev().cmp(prime.iter().rev()).is_lt()
        && VerifyingKey::from_bytes(&point).is_ok_and(|key| !key.is_weak())
}

fn verify(wire: &[u8], policy: &Value) -> Result<Verified, Code> {
    let p = fields(
        policy,
        &[
            "sender",
            "recipient",
            "halaqa_id",
            "charter_hash",
            "epoch",
            "key_id",
            "public_key",
            "now",
            "revoked",
        ],
        "test_policy",
    )?;
    require(
        ["sender", "recipient", "halaqa_id", "key_id"]
            .iter()
            .all(|k| token(&p[*k]))
            && digest(&p["charter_hash"])
            && p["revoked"].is_boolean(),
        "test_policy",
    )?;
    uint(&p["epoch"], "test_policy")?;
    let now = uint(&p["now"], "test_policy")?;
    let public_key = base64(&p["public_key"], "signed_encoding", Some(32))?;
    require((1..=12_288).contains(&wire.len()), "signed_wire_limit")?;
    let value = decode(wire)?;
    let e = fields(
        &value,
        &[
            "schema",
            "candidate",
            "key_id",
            "issued_at",
            "expires_at",
            "signature",
        ],
        "signed_fields",
    )?;
    require(
        e["schema"] == "halaqa-federation-signed-experiment/draft-2",
        "signed_schema",
    )?;
    require(token(&e["key_id"]), "signed_key")?;
    let issued = uint(&e["issued_at"], "signed_time")?;
    let expires = uint(&e["expires_at"], "signed_time")?;
    require(issued < expires && expires - issued <= 300, "signed_time")?;
    let raw = base64(&e["candidate"], "signed_encoding", None)?;
    let signature = base64(&e["signature"], "signed_encoding", Some(64))?;
    let (m, payload) = candidate(&raw)?;
    require(
        e["key_id"] == p["key_id"] && m["sender"] == p["sender"],
        "test_key_binding",
    )?;
    require(p["revoked"] == false, "test_key_revoked")?;
    require(
        ["recipient", "halaqa_id", "charter_hash", "epoch"]
            .iter()
            .all(|k| m[*k] == p[*k]),
        "test_context",
    )?;
    require(issued <= now && now < expires, "test_expiry")?;
    let key_id = e["key_id"].as_str().expect("token checked").as_bytes();
    let mut transcript = DOMAIN.to_vec();
    transcript.extend_from_slice(&(key_id.len() as u32).to_be_bytes());
    transcript.extend_from_slice(key_id);
    transcript.extend_from_slice(&issued.to_be_bytes());
    transcript.extend_from_slice(&expires.to_be_bytes());
    transcript.extend_from_slice(&(raw.len() as u32).to_be_bytes());
    transcript.extend_from_slice(&raw);
    let key_bytes: [u8; 32] = public_key.try_into().expect("length checked");
    require(
        point_encoding_allowed(&key_bytes) && point_encoding_allowed(&signature[..32]),
        "invalid_signature",
    )?;
    let key = VerifyingKey::from_bytes(&key_bytes).map_err(|_| "invalid_signature")?;
    let signature = Signature::from_slice(&signature).map_err(|_| "invalid_signature")?;
    key.verify_strict(&transcript, &signature)
        .map_err(|_| "invalid_signature")?;
    Ok(Verified {
        payload,
        transcript,
    })
}

fn check(bytes: &[u8]) -> Result<Value, String> {
    require(bytes.len() <= 2_000_000, "corpus_limit")?;
    let value = decode(bytes)?;
    let corpus = fields(&value, &["schema", "scope", "vectors"], "corpus")?;
    require(
        corpus["schema"] == "halaqa-federation-signed-vectors/draft-2"
            && corpus["scope"] == "offline-signed-test-only",
        "corpus",
    )?;
    let vectors = corpus["vectors"].as_array().ok_or("corpus")?;
    let (mut positive, mut negative) = (0, 0);
    let mut names = HashSet::new();
    for v in vectors {
        let v = fields(
            v,
            &[
                "name",
                "wire_base64",
                "test_policy",
                "expected",
                "reason",
                "payload_base64",
                "transcript_base64",
            ],
            "corpus",
        )?;
        require(token(&v["name"]), "corpus")?;
        let name = v["name"].as_str().expect("token checked");
        require(names.insert(name), "corpus")?;
        let wire = base64(&v["wire_base64"], "corpus", None)?;
        let matches = match verify(&wire, &v["test_policy"]) {
            Ok(result) => {
                positive += 1;
                v["expected"] == VERDICT
                    && v["reason"].is_null()
                    && v["payload_base64"] == STANDARD.encode(result.payload)
                    && v["transcript_base64"] == STANDARD.encode(result.transcript)
            }
            Err(reason) => {
                negative += 1;
                v["expected"] == "REFUSED_SIGNED_TEST"
                    && v["reason"] == reason
                    && v["payload_base64"].is_null()
                    && v["transcript_base64"].is_null()
            }
        };
        if !matches {
            return Err(format!("corpus_disagreement:{name}"));
        }
    }
    require(positive > 0 && negative > 0, "corpus")?;
    Ok(
        json!({"scope":"offline-signed-test-only", "implementation":"independent-rust-dalek",
        "counts":{VERDICT:positive,"REFUSED_SIGNED_TEST":negative},
        "authority_verified":false,"production_receiver":false}),
    )
}

fn main() {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    if args.len() > 1 {
        eprintln!("usage: halaqa-signed-draft-conformance [corpus.json]");
        std::process::exit(2);
    }
    let default = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../halaqa_federation_draft/signed-vectors.json");
    let path = args.first().map_or(default.as_path(), Path::new);
    let result = (|| -> Result<Value, String> {
        let mut bytes = Vec::new();
        File::open(path)
            .map_err(|e| e.to_string())?
            .take(2_000_001)
            .read_to_end(&mut bytes)
            .map_err(|e| e.to_string())?;
        check(&bytes)
    })();
    match result {
        Ok(summary) => println!("{summary}"),
        Err(error) => {
            eprintln!("{error}");
            std::process::exit(1);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    const CORPUS: &[u8] = include_bytes!("../../halaqa_federation_draft/signed-vectors.json");

    fn fixture() -> (Vec<u8>, Value) {
        let corpus = decode(CORPUS).unwrap();
        let v = &corpus["vectors"][0];
        (
            base64(&v["wire_base64"], "corpus", None).unwrap(),
            v["test_policy"].clone(),
        )
    }

    #[test]
    fn every_vector_and_exact_transcript_matches() {
        let summary = check(CORPUS).unwrap();
        assert_eq!(summary["counts"][VERDICT], 8);
        assert_eq!(summary["counts"]["REFUSED_SIGNED_TEST"], 66);
        assert_eq!(summary["authority_verified"], false);
    }

    #[test]
    fn duplicates_trailing_values_and_depth_fail_closed() {
        for (bytes, reason) in [
            (b"{\"x\":1,\"x\":2}".as_slice(), "duplicate_key"),
            (b"{} {}".as_slice(), "invalid_json"),
            (b"[[[[[[[[[0]]]]]]]]]".as_slice(), "invalid_json"),
        ] {
            assert_eq!(decode(bytes).unwrap_err(), reason);
        }
    }

    #[test]
    fn signature_and_key_cannot_be_substituted() {
        let (wire, policy) = fixture();
        let mut envelope = decode(&wire).unwrap();
        envelope["signature"] = STANDARD.encode([0_u8; 64]).into();
        assert!(matches!(
            verify(&serde_json::to_vec(&envelope).unwrap(), &policy),
            Err("invalid_signature")
        ));
        envelope["public_key"] = policy["public_key"].clone();
        assert!(matches!(
            verify(&serde_json::to_vec(&envelope).unwrap(), &policy),
            Err("signed_fields")
        ));
    }

    #[test]
    fn policy_booleans_and_integers_are_not_interchangeable() {
        let (wire, policy) = fixture();
        for (field, value) in [
            ("epoch", json!(true)),
            ("now", json!(1.0)),
            ("revoked", json!(0)),
        ] {
            let mut changed = policy.clone();
            changed[field] = value;
            assert!(matches!(verify(&wire, &changed), Err("test_policy")));
        }
    }

    #[test]
    fn identity_key_and_trivial_signature_are_rejected() {
        let (wire, mut policy) = fixture();
        let mut identity = [0_u8; 32];
        identity[0] = 1;
        policy["public_key"] = STANDARD.encode(identity).into();
        let mut signature = [0_u8; 64];
        signature[0] = 1;
        let mut envelope = decode(&wire).unwrap();
        envelope["signature"] = STANDARD.encode(signature).into();
        assert!(matches!(
            verify(&serde_json::to_vec(&envelope).unwrap(), &policy),
            Err("invalid_signature")
        ));
    }

    #[test]
    fn corpus_cannot_claim_authority_or_change_verified_bytes() {
        for (field, value) in [("expected", "AUTHORIZED"), ("transcript_base64", "eA==")] {
            let mut corpus = decode(CORPUS).unwrap();
            corpus["vectors"][0][field] = value.into();
            assert!(check(&serde_json::to_vec(&corpus).unwrap()).is_err());
        }
    }
}

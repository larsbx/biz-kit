//! Offline experiment only. No network, Port, admission or writer integration.
use base64::{Engine, engine::general_purpose::STANDARD};
use ed25519_dalek::{Signature, VerifyingKey};
use serde::{
    Deserialize, Deserializer,
    de::{self, MapAccess, SeqAccess, Visitor},
};
use serde_json::{Map, Number, Value, json};
use sha2::{Digest, Sha256};
use std::{collections::BTreeSet, fmt};

const SOURCE: &str = "11eb6309ec6caccb6aab3c821eba2311881c9ba0";
const VERDICT: &str = "SIGNATURE_VALID_AUTHORITY_UNVERIFIED";
const DOMAIN: &[u8] = b"halaqa.federation.signed-experiment/draft-1\0";
const MAX_EPOCH: u64 = (1 << 53) - 1;
type Refusal = &'static str;
type Result<T> = std::result::Result<T, Refusal>;

// Value's ordinary deserializer overwrites duplicate keys. Walk every map
// ourselves, including nested maps, before interpreting any fields.
struct Unique(Value);
impl<'de> Deserialize<'de> for Unique {
    fn deserialize<D: Deserializer<'de>>(d: D) -> std::result::Result<Self, D::Error> {
        struct Walk;
        impl<'de> Visitor<'de> for Walk {
            type Value = Unique;
            fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
                f.write_str("JSON value")
            }
            fn visit_bool<E: de::Error>(self, v: bool) -> std::result::Result<Unique, E> {
                Ok(Unique(v.into()))
            }
            fn visit_i64<E: de::Error>(self, v: i64) -> std::result::Result<Unique, E> {
                Ok(Unique(v.into()))
            }
            fn visit_u64<E: de::Error>(self, v: u64) -> std::result::Result<Unique, E> {
                Ok(Unique(v.into()))
            }
            fn visit_f64<E: de::Error>(self, v: f64) -> std::result::Result<Unique, E> {
                Number::from_f64(v)
                    .map(|n| Unique(Value::Number(n)))
                    .ok_or_else(|| E::custom("invalid_json"))
            }
            fn visit_str<E: de::Error>(self, v: &str) -> std::result::Result<Unique, E> {
                Ok(Unique(v.into()))
            }
            fn visit_string<E: de::Error>(self, v: String) -> std::result::Result<Unique, E> {
                Ok(Unique(v.into()))
            }
            fn visit_unit<E: de::Error>(self) -> std::result::Result<Unique, E> {
                Ok(Unique(Value::Null))
            }
            fn visit_seq<A: SeqAccess<'de>>(
                self,
                mut seq: A,
            ) -> std::result::Result<Unique, A::Error> {
                let mut values = Vec::new();
                while let Some(Unique(v)) = seq.next_element()? {
                    values.push(v);
                }
                Ok(Unique(Value::Array(values)))
            }
            fn visit_map<A: MapAccess<'de>>(
                self,
                mut map: A,
            ) -> std::result::Result<Unique, A::Error> {
                let mut values = Map::new();
                while let Some(key) = map.next_key::<String>()? {
                    if values.contains_key(&key) {
                        return Err(de::Error::custom("duplicate_key"));
                    }
                    let Unique(v) = map.next_value()?;
                    values.insert(key, v);
                }
                Ok(Unique(Value::Object(values)))
            }
        }
        // Preserve lexical integer types: serde_json otherwise turns -0 into
        // a float. Parsing semantics here never reserializes signed bytes.
        let raw = Box::<serde_json::value::RawValue>::deserialize(d)?;
        let text = raw.get();
        if text
            .as_bytes()
            .first()
            .is_some_and(|b| *b == b'-' || b.is_ascii_digit())
        {
            let integer_token = !text.bytes().any(|b| b".eE".contains(&b));
            let value = if integer_token {
                text.parse::<i64>()
                    .map(Value::from)
                    .ok()
                    .or_else(|| text.parse::<u64>().map(Value::from).ok())
                    .unwrap_or(Value::Null)
            } else {
                serde_json::from_str(text).unwrap_or(Value::Null)
            };
            // Out-of-range numbers become an invalid typed value. Every
            // numeric slot is checked against the smaller 0..2^53-1 bound;
            // nonnumeric slots also refuse null. No oversized number passes.
            return Ok(Unique(value));
        }
        let mut json = serde_json::Deserializer::from_str(text);
        json.deserialize_any(Walk).map_err(de::Error::custom)
    }
}
fn parse(wire: &[u8]) -> Result<Value> {
    let (mut depth, mut quoted, mut escaped) = (0i32, false, false);
    for &b in wire {
        if quoted {
            if escaped {
                escaped = false;
            } else if b == b'\\' {
                escaped = true;
            } else if b == b'"' {
                quoted = false;
            }
        } else {
            match b {
                b'"' => quoted = true,
                b'{' | b'[' => {
                    depth += 1;
                    if depth > 8 {
                        return Err("invalid_json");
                    }
                }
                b'}' | b']' => {
                    depth -= 1;
                    if depth < 0 {
                        return Err("invalid_json");
                    }
                }
                _ => (),
            }
        }
    }
    serde_json::from_slice::<Unique>(wire)
        .map(|v| v.0)
        .map_err(|e| {
            if e.to_string().starts_with("duplicate_key") {
                "duplicate_key"
            } else {
                "invalid_json"
            }
        })
}
fn fields(v: &Value, required: &[&str], reason: Refusal) -> Result<()> {
    match v.as_object() {
        Some(m) if m.len() == required.len() && required.iter().all(|k| m.contains_key(*k)) => {
            Ok(())
        }
        _ => Err(reason),
    }
}
fn token(v: &Value) -> bool {
    v.as_str().is_some_and(|s| {
        !s.is_empty()
            && s.len() <= 128
            && s.as_bytes()[0].is_ascii_alphanumeric()
            && s.bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"._:-".contains(&b))
    })
}
fn hash(v: &Value) -> bool {
    v.as_str().is_some_and(|s| {
        s.len() == 71
            && s.starts_with("sha256:")
            && s.as_bytes()[7..]
                .iter()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(b))
    })
}
fn integer(v: &Value) -> Option<u64> {
    v.as_u64().filter(|&n| n <= MAX_EPOCH)
}
fn b64(v: &Value, size: Option<usize>, reason: Refusal) -> Result<Vec<u8>> {
    let s = v.as_str().ok_or(reason)?;
    if size.is_some_and(|n| s.len() != n.div_ceil(3) * 4) {
        return Err(reason);
    }
    let data = STANDARD.decode(s).map_err(|_| reason)?;
    if STANDARD.encode(&data) != s || size.is_some_and(|n| n != data.len()) {
        return Err(reason);
    }
    Ok(data)
}
fn digest(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
fn decode(wire: &[u8]) -> Result<(Value, Vec<u8>)> {
    if wire.is_empty() || wire.len() > 8192 {
        return Err("wire_limit");
    }
    let v = parse(wire)?;
    fields(
        &v,
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
    if v["schema"] != "halaqa-federation-candidate/draft-0" {
        return Err("schema");
    }
    if ["message_id", "halaqa_id", "sender", "recipient"]
        .iter()
        .any(|k| !token(&v[k]))
    {
        return Err("identifier");
    }
    if !hash(&v["charter_hash"]) || !hash(&v["payload_hash"]) {
        return Err("digest_format");
    }
    if integer(&v["epoch"]).is_none() {
        return Err("epoch");
    }
    if v["kind"] != "proposal" && v["kind"] != "public_activity" {
        return Err("kind");
    }
    let parents = v["parents"].as_array().ok_or("parents")?;
    if parents.len() > 16
        || parents.iter().any(|p| !hash(p))
        || parents.windows(2).any(|p| p[0].as_str() >= p[1].as_str())
    {
        return Err("parents");
    }
    let payload = b64(&v["payload"], None, "payload_encoding")?;
    if payload.is_empty() || payload.len() > 4096 {
        return Err("payload_limit");
    }
    if v["payload_hash"] != format!("sha256:{}", digest(&payload)) {
        return Err("payload_digest");
    }
    Ok((v, payload))
}
fn policy(p: &Value) -> Result<Vec<u8>> {
    fields(
        p,
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
    if ["sender", "recipient", "halaqa_id", "key_id"]
        .iter()
        .any(|k| !token(&p[k]))
        || !hash(&p["charter_hash"])
        || integer(&p["epoch"]).is_none()
        || integer(&p["now"]).is_none()
        || !p["revoked"].is_boolean()
    {
        return Err("test_policy");
    }
    b64(&p["public_key"], Some(32), "signed_encoding")
}
fn transcript(candidate: &[u8], key: &str, issued: u64, expires: u64) -> Vec<u8> {
    // Called only after length, ASCII and timestamp bounds have been checked.
    let mut out = DOMAIN.to_vec();
    out.extend_from_slice(&(key.len() as u32).to_be_bytes());
    out.extend_from_slice(key.as_bytes());
    out.extend_from_slice(&issued.to_be_bytes());
    out.extend_from_slice(&expires.to_be_bytes());
    out.extend_from_slice(&(candidate.len() as u32).to_be_bytes());
    out.extend_from_slice(candidate);
    out
}
#[derive(Debug)]
struct SignatureValidAuthorityUnverified {
    payload: Vec<u8>,
    transcript: Vec<u8>,
}
fn verify(wire: &[u8], p: &Value) -> Result<SignatureValidAuthorityUnverified> {
    let pk = policy(p)?;
    if wire.is_empty() || wire.len() > 12288 {
        return Err("signed_wire_limit");
    }
    let v = parse(wire)?;
    fields(
        &v,
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
    if v["schema"] != "halaqa-federation-signed-experiment/draft-1" {
        return Err("signed_schema");
    }
    if !token(&v["key_id"]) {
        return Err("signed_key");
    }
    let issued = integer(&v["issued_at"]).ok_or("signed_time")?;
    let expires = integer(&v["expires_at"]).ok_or("signed_time")?;
    if issued >= expires || expires - issued > 300 {
        return Err("signed_time");
    }
    let candidate = b64(&v["candidate"], None, "signed_encoding")?;
    let signature = b64(&v["signature"], Some(64), "signed_encoding")?;
    let (message, payload) = decode(&candidate)?;
    if v["key_id"] != p["key_id"] || message["sender"] != p["sender"] {
        return Err("test_key_binding");
    }
    if p["revoked"] == true {
        return Err("test_key_revoked");
    }
    if ["recipient", "halaqa_id", "charter_hash", "epoch"]
        .iter()
        .any(|k| message[k] != p[k])
    {
        return Err("test_context");
    }
    let now = integer(&p["now"]).ok_or("test_policy")?;
    if now < issued || now >= expires {
        return Err("test_expiry");
    }
    let signed = transcript(
        &candidate,
        v["key_id"].as_str().ok_or("signed_key")?,
        issued,
        expires,
    );
    let key = VerifyingKey::from_bytes(&pk.try_into().map_err(|_| "signed_encoding")?)
        .map_err(|_| "invalid_signature")?;
    let sig = Signature::from_slice(&signature).map_err(|_| "invalid_signature")?;
    key.verify_strict(&signed, &sig)
        .map_err(|_| "invalid_signature")?;
    Ok(SignatureValidAuthorityUnverified {
        payload,
        transcript: signed,
    })
}

// Fixed in-repo compile-time corpus: no caller-selected file, policy or stdin.
const SIGNED: &[u8] = include_bytes!("../../halaqa_federation_draft/signed-vectors.json");
#[cfg(test)]
const UNSIGNED: &[u8] = include_bytes!("../../halaqa_federation_draft/vectors.json");
const SIGNED_HASH: &str = "03d87ac6cbb664135b7fd03a9450355b01fb42c1f486f1c8e76764795b15ac04";
#[cfg(test)]
const UNSIGNED_HASH: &str = "e4ef86ff11a300f138c6ab4ac24c788f2a3ae84e034737e5e69a120ff11a1d72";
fn corpus(bytes: &[u8], expected_hash: &str, signed: bool) -> std::result::Result<Value, String> {
    if digest(bytes) != expected_hash {
        return Err("source-pinned corpus changed".into());
    }
    // Trusted, size-pinned fixture container; the untrusted frame parser below is depth bounded.
    let root: Value = serde_json::from_slice(bytes).map_err(|e| e.to_string())?;
    let (schema, scope) = if signed {
        (
            "halaqa-federation-signed-vectors/draft-1",
            "offline-signed-test-only",
        )
    } else {
        (
            "halaqa-federation-format-vectors/draft-0",
            "offline-format-only",
        )
    };
    if root["schema"] != schema || root["scope"] != scope {
        return Err("corpus scope".into());
    }
    let vectors = root["vectors"].as_array().ok_or("missing vectors")?;
    let mut names = BTreeSet::new();
    let (mut valid, mut refused) = (0, 0);
    for v in vectors {
        if !token(&v["name"]) || !names.insert(v["name"].as_str().unwrap()) {
            return Err("vector name".into());
        }
        let wire = b64(&v["wire_base64"], None, "corpus_encoding")?;
        let result = if signed {
            verify(&wire, &v["test_policy"]).map(|r| (r.payload, Some(r.transcript)))
        } else {
            decode(&wire).map(|(_, payload)| (payload, None))
        };
        match result {
            Ok((payload, transcript)) => {
                let verdict = if signed {
                    VERDICT
                } else {
                    "FORMAT_ONLY_UNVERIFIED"
                };
                if v["expected"] != verdict
                    || !v["reason"].is_null()
                    || v["payload_base64"] != STANDARD.encode(payload)
                    || transcript.is_some_and(|t| v["transcript_base64"] != STANDARD.encode(t))
                {
                    return Err(format!("{}: changed verified bytes or verdict", v["name"]));
                }
                valid += 1;
            }
            Err(reason) => {
                let verdict = if signed {
                    "REFUSED_SIGNED_TEST"
                } else {
                    "REFUSED_FORMAT"
                };
                if v["expected"] != verdict
                    || v["reason"] != reason
                    || !v["payload_base64"].is_null()
                    || (signed && !v["transcript_base64"].is_null())
                {
                    return Err(format!("{}: unexpected refusal {reason}", v["name"]));
                }
                refused += 1;
            }
        }
    }
    let expected = if signed { (8, 40) } else { (6, 34) };
    if (valid, refused) != expected {
        return Err("corpus count".into());
    }
    Ok(json!({"valid_unverified":valid,"refused":refused,"sha256":expected_hash}))
}
// Fixed synthetic edge probes are diagnostics, not additional accepted corpus.
// Keep these separate so corpus agreement never hides backend disagreements.
fn edge_probes() -> Value {
    let root: Value = serde_json::from_slice(SIGNED).expect("pinned corpus");
    let fixture = &root["vectors"][0];
    let raw = b64(&fixture["wire_base64"], None, "encoding").unwrap();
    let mut envelope = parse(&raw).unwrap();
    let mut p = fixture["test_policy"].clone();
    let mut identity = [0u8; 32];
    identity[0] = 1;
    let mut weak = [0u8; 64];
    weak[0] = 1;
    p["public_key"] = STANDARD.encode(identity).into();
    envelope["signature"] = STANDARD.encode(weak).into();
    let weak_outcome = match verify(&serde_json::to_vec(&envelope).unwrap(), &p) {
        Ok(_) => VERDICT,
        Err(reason) => reason,
    };
    let candidate = b64(&envelope["candidate"], None, "encoding").unwrap();
    let raw = std::str::from_utf8(&candidate).unwrap();
    let probes = [
        ("lone-surrogate", raw.replace("actor:alpha", r"\ud800")),
        (
            "negative-zero-epoch",
            raw.replace("\"epoch\":1", "\"epoch\":-0"),
        ),
        (
            "overflow-epoch",
            raw.replace("\"epoch\":1", "\"epoch\":1e400"),
        ),
    ];
    let mut outcomes = Map::new();
    outcomes.insert("weak-identity-key".into(), weak_outcome.into());
    for (name, wire) in probes {
        let outcome = match decode(wire.as_bytes()) {
            Ok(_) => "FORMAT_ONLY_UNVERIFIED",
            Err(reason) => reason,
        };
        outcomes.insert(name.into(), outcome.into());
    }
    Value::Object(outcomes)
}
fn main() -> std::result::Result<(), String> {
    if std::env::args_os().len() != 1 {
        return Err("offline corpus runner accepts no inputs".into());
    }
    let signed = corpus(SIGNED, SIGNED_HASH, true)?;
    println!(
        "{}",
        json!({"source_revision":SOURCE,"scope":"offline-conformance-only",
        "signature_verdict":VERDICT,"signed":signed,"edge_probes":edge_probes(),
        "authority_verified":false,"production_receiver":false})
    );
    Ok(())
}

#[cfg(test)]
mod tests;

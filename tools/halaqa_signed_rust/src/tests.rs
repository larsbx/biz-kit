use super::*;
use ed25519_dalek::{Signer, SigningKey};

// Fresh fixtures, independent of the pinned vector expectations. The transcript
// assembly here deliberately does not call the verifier's transcript function.
fn fixture() -> (Value, Value, SigningKey) {
    let key = SigningKey::from_bytes(&[0x5a; 32]);
    let payload = b"{ \"independent\": true }\n";
    let candidate = json!({"schema":"halaqa-federation-candidate/draft-0",
        "message_id":"rust:fresh", "halaqa_id":"circle:rust", "charter_hash":format!("sha256:{}","2".repeat(64)),
        "epoch":3, "sender":"actor:rust", "recipient":"actor:local", "kind":"proposal", "parents":[],
        "payload":STANDARD.encode(payload), "payload_hash":format!("sha256:{}",digest(payload))});
    let envelope = json!({"schema":"halaqa-federation-signed-experiment/draft-1",
        "key_id":"rust:test", "issued_at":100, "expires_at":400,
        "candidate":STANDARD.encode(serde_json::to_vec(&candidate).unwrap()), "signature":""});
    let policy = json!({"key_id":"rust:test", "public_key":STANDARD.encode(key.verifying_key().as_bytes()),
        "sender":"actor:rust", "recipient":"actor:local", "halaqa_id":"circle:rust",
        "charter_hash":format!("sha256:{}","2".repeat(64)), "epoch":3, "now":101, "revoked":false});
    (envelope, policy, key)
}
fn sign(v: &mut Value, key: &SigningKey) {
    let raw = STANDARD.decode(v["candidate"].as_str().unwrap()).unwrap();
    let id = v["key_id"].as_str().unwrap().as_bytes();
    let mut bytes = b"halaqa.federation.signed-experiment/draft-1\0".to_vec();
    bytes.extend((id.len() as u32).to_be_bytes());
    bytes.extend(id);
    bytes.extend(v["issued_at"].as_u64().unwrap().to_be_bytes());
    bytes.extend(v["expires_at"].as_u64().unwrap().to_be_bytes());
    bytes.extend((raw.len() as u32).to_be_bytes());
    bytes.extend(raw);
    v["signature"] = STANDARD.encode(key.sign(&bytes).to_bytes()).into();
}
fn wire(v: &Value) -> Vec<u8> {
    serde_json::to_vec(v).unwrap()
}
fn change_candidate(v: &mut Value, f: impl FnOnce(&mut Value)) {
    let mut c: Value =
        serde_json::from_slice(&STANDARD.decode(v["candidate"].as_str().unwrap()).unwrap())
            .unwrap();
    f(&mut c);
    v["candidate"] = STANDARD.encode(wire(&c)).into();
}
fn refused(v: &Value, p: &Value, expected: &str) {
    assert_eq!(verify(&wire(v), p).unwrap_err(), expected);
}

#[test]
fn exact_pinned_signed_corpus() {
    corpus(SIGNED, SIGNED_HASH, true).unwrap();
}
#[test]
fn corpus_tampering_is_not_a_repin() {
    let mut changed = SIGNED.to_vec();
    changed.push(b' ');
    assert!(corpus(&changed, SIGNED_HASH, true).is_err());
}
#[test]
fn fresh_signature_preserves_payload_and_original_candidate() {
    let (mut v, p, k) = fixture();
    sign(&mut v, &k);
    let r = verify(&wire(&v), &p).unwrap();
    assert_eq!(r.payload, b"{ \"independent\": true }\n");
    let raw = STANDARD.decode(v["candidate"].as_str().unwrap()).unwrap();
    assert!(r.transcript.ends_with(&raw));
    assert_eq!(&r.transcript[..DOMAIN.len()], DOMAIN);
    assert_eq!(
        &r.transcript[DOMAIN.len()..DOMAIN.len() + 4],
        &9u32.to_be_bytes()
    );
    // Stateless verification repeats; it does not create replay consumption.
    verify(&wire(&v), &p).unwrap();
}
#[test]
fn modified_payload_with_recomputed_digest_still_fails_signature() {
    let (mut v, p, k) = fixture();
    sign(&mut v, &k);
    change_candidate(&mut v, |c| {
        c["payload"] = STANDARD.encode(b"changed").into();
        c["payload_hash"] = format!("sha256:{}", digest(b"changed")).into();
    });
    refused(&v, &p, "invalid_signature");
}
#[test]
fn candidate_whitespace_is_bound_outer_whitespace_is_not() {
    let (mut v, p, k) = fixture();
    sign(&mut v, &k);
    verify(&serde_json::to_vec_pretty(&v).unwrap(), &p).unwrap();
    let raw = STANDARD.decode(v["candidate"].as_str().unwrap()).unwrap();
    v["candidate"] = STANDARD.encode([raw, b"\n".to_vec()].concat()).into();
    refused(&v, &p, "invalid_signature");
}
#[test]
fn changed_signature_and_wrong_public_key_fail() {
    let (mut v, mut p, k) = fixture();
    sign(&mut v, &k);
    let original = v.clone();
    let mut sig = STANDARD.decode(v["signature"].as_str().unwrap()).unwrap();
    sig[31] ^= 1;
    v["signature"] = STANDARD.encode(sig).into();
    refused(&v, &p, "invalid_signature");
    p["public_key"] = STANDARD
        .encode(
            SigningKey::from_bytes(&[0x6b; 32])
                .verifying_key()
                .as_bytes(),
        )
        .into();
    refused(&original, &p, "invalid_signature");
}
#[test]
fn correctly_signed_wrong_recipient_epoch_and_identity_are_refused() {
    let (v, p, k) = fixture();
    for (field, value, reason) in [
        ("recipient", json!("actor:else"), "test_context"),
        ("epoch", json!(4), "test_context"),
        ("sender", json!("actor:else"), "test_key_binding"),
        ("halaqa_id", json!("circle:else"), "test_context"),
        (
            "charter_hash",
            json!(format!("sha256:{}", "3".repeat(64))),
            "test_context",
        ),
    ] {
        let mut changed = v.clone();
        change_candidate(&mut changed, |c| c[field] = value);
        sign(&mut changed, &k);
        refused(&changed, &p, reason);
    }
}
#[test]
fn revoked_key_and_half_open_lifetime_are_external_test_inputs() {
    let (mut v, mut p, k) = fixture();
    sign(&mut v, &k);
    p["revoked"] = true.into();
    refused(&v, &p, "test_key_revoked");
    p["revoked"] = false.into();
    for (now, valid) in [(99, false), (100, true), (399, true), (400, false)] {
        p["now"] = now.into();
        if valid {
            verify(&wire(&v), &p).unwrap();
        } else {
            refused(&v, &p, "test_expiry");
        }
    }
}
#[test]
fn malformed_encodings_numbers_and_limits_fail_closed() {
    let (mut v, p, k) = fixture();
    sign(&mut v, &k);
    for (field, value, reason) in [
        ("candidate", json!("Zh=="), "signed_encoding"),
        ("candidate", json!(" \n"), "signed_encoding"),
        (
            "signature",
            json!(STANDARD.encode([0; 63])),
            "signed_encoding",
        ),
        ("issued_at", json!(true), "signed_time"),
        ("expires_at", json!(400.0), "signed_time"),
        ("key_id", json!("rust:\n"), "signed_key"),
        ("issued_at", json!(MAX_EPOCH + 1), "signed_time"),
    ] {
        let mut changed = v.clone();
        changed[field] = value;
        refused(&changed, &p, reason);
    }
    assert_eq!(verify(&[b' '; 12289], &p).unwrap_err(), "signed_wire_limit");
    assert_eq!(verify(&[0xff], &p).unwrap_err(), "invalid_json");
    assert_eq!(parse(b"[[[[[[[[[]]]]]]]]]").unwrap_err(), "invalid_json");
    assert_eq!(
        parse(br#"{"x":1,"\u0078":2}"#).unwrap_err(),
        "duplicate_key"
    );
    assert_eq!(
        parse(br#"{"nested":{"x":1,"x":2}}"#).unwrap_err(),
        "duplicate_key"
    );
    assert_eq!(parse(b"{\"x\":NaN}").unwrap_err(), "invalid_json");
}
#[test]
fn remote_authority_claim_cannot_become_a_success() {
    let (mut v, p, k) = fixture();
    sign(&mut v, &k);
    v["authorized"] = true.into();
    refused(&v, &p, "signed_fields");
    v.as_object_mut().unwrap().remove("authorized");
    change_candidate(&mut v, |c| c["authority_verified"] = true.into());
    sign(&mut v, &k);
    refused(&v, &p, "fields");
}
#[test]
fn local_policy_shape_and_types_are_not_remote_claims() {
    let (mut v, p, k) = fixture();
    sign(&mut v, &k);
    for (field, value) in [
        ("epoch", json!(true)),
        ("now", json!(101.0)),
        ("revoked", json!(0)),
        ("sender", json!("é")),
    ] {
        let mut changed = p.clone();
        changed[field] = value;
        refused(&v, &changed, "test_policy");
    }
    let mut changed = p.clone();
    changed["authority"] = true.into();
    refused(&v, &changed, "test_policy");
}
#[test]
fn weak_identity_key_and_noncanonical_scalar_are_refused() {
    let (mut v, mut p, k) = fixture();
    sign(&mut v, &k);
    let mut sig = STANDARD.decode(v["signature"].as_str().unwrap()).unwrap();
    sig[63] |= 0x80;
    v["signature"] = STANDARD.encode(sig).into();
    refused(&v, &p, "invalid_signature");
    let mut identity = [0u8; 32];
    identity[0] = 1;
    p["public_key"] = STANDARD.encode(identity).into();
    let mut weak = [0u8; 64];
    weak[0] = 1;
    v["signature"] = STANDARD.encode(weak).into();
    refused(&v, &p, "invalid_signature");
}

#[test]
fn unsigned_probe_records_lone_surrogate_refusal_reason_difference() {
    assert_eq!(digest(UNSIGNED), UNSIGNED_HASH);
    let root: Value = serde_json::from_slice(UNSIGNED).unwrap();
    let mut differences = Vec::new();
    for v in root["vectors"].as_array().unwrap() {
        let wire = b64(&v["wire_base64"], None, "encoding").unwrap();
        match decode(&wire) {
            Ok((_, payload)) => {
                assert_eq!(v["expected"], "FORMAT_ONLY_UNVERIFIED");
                assert_eq!(v["payload_base64"], STANDARD.encode(payload));
            }
            Err(reason) => {
                assert_eq!(v["expected"], "REFUSED_FORMAT");
                if v["reason"] != reason {
                    differences.push((v["name"].as_str().unwrap(), reason));
                }
            }
        }
    }
    // Diagnostic only, not claimed as unsigned exact-reason conformance.
    assert_eq!(differences, vec![("unpaired-surrogate", "invalid_json")]);
}

#[test]
fn numeric_lexemes_preserve_integer_rules_without_changing_signed_bytes() {
    let (mut v, mut p, k) = fixture();
    let raw =
        String::from_utf8(STANDARD.decode(v["candidate"].as_str().unwrap()).unwrap()).unwrap();
    let changed = raw.replace("\"epoch\":3", "\"epoch\":-0");
    assert_ne!(raw, changed);
    v["candidate"] = STANDARD.encode(changed.as_bytes()).into();
    p["epoch"] = 0.into();
    sign(&mut v, &k);
    let result = verify(&wire(&v), &p).unwrap();
    assert!(result.transcript.ends_with(changed.as_bytes()));
    for n in [
        "-0.0",
        "0e0",
        "1e400",
        "9007199254740992",
        "184467440737095516160",
    ] {
        let changed = raw.replace("\"epoch\":3", &format!("\"epoch\":{n}"));
        v["candidate"] = STANDARD.encode(changed.as_bytes()).into();
        refused(&v, &p, "epoch");
    }
    // The strict Unicode decoder differs from Python only in refusal reason.
    assert_eq!(
        parse(br#"{"sender":"\ud800"}"#).unwrap_err(),
        "invalid_json"
    );
}
#[test]
fn fixed_diagnostic_probes_do_not_hide_reference_disagreement() {
    assert_eq!(
        edge_probes(),
        json!({"weak-identity-key":"invalid_signature",
        "lone-surrogate":"invalid_json", "negative-zero-epoch":"FORMAT_ONLY_UNVERIFIED",
        "overflow-epoch":"epoch"})
    );
}

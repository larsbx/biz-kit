//! CoopEventCanonicalV1 core encoder — pure Rust, no BEAM dependency.
//!
//! Strict deterministic subset of CBOR (RFC 8949 §4.2.1 core deterministic
//! encoding) as frozen in SUBSTRATE.md §1. This module is used both by the
//! NIF layer (src/lib.rs) and by `cargo test` (BEAM-independent verification
//! of the committed test vectors).

/// PLACEHOLDER — awaiting charter declaration. Mirrored in
/// `CoopSubstrate.Constants.max_canonical_bytes/0`.
pub const MAX_BYTES: usize = 65_536;
/// PLACEHOLDER — awaiting charter declaration. Mirrored in
/// `CoopSubstrate.Constants.max_canonical_depth/0`.
pub const MAX_DEPTH: usize = 32;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Value {
    Int(i64),
    Text(String),
    Bytes(Vec<u8>),
    Bool(bool),
    Null,
    List(Vec<Value>),
    /// Unsorted pairs; sorted canonically (by encoded key bytes) at encode time.
    Map(Vec<(String, Value)>),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EncodeError {
    FloatForbidden,
    IntOutOfRange,
    InvalidUtf8,
    BadMapKey,
    ForbiddenType,
    BadBytesWrapper,
    DuplicateMapKey,
    TooLarge,
    TooDeep,
}

impl EncodeError {
    pub fn as_str(&self) -> &'static str {
        match self {
            EncodeError::FloatForbidden => "float_forbidden",
            EncodeError::IntOutOfRange => "int_out_of_range",
            EncodeError::InvalidUtf8 => "invalid_utf8",
            EncodeError::BadMapKey => "bad_map_key",
            EncodeError::ForbiddenType => "forbidden_type",
            EncodeError::BadBytesWrapper => "bad_bytes_wrapper",
            EncodeError::DuplicateMapKey => "duplicate_map_key",
            EncodeError::TooLarge => "too_large",
            EncodeError::TooDeep => "too_deep",
        }
    }
}

/// Encode a logical value to CoopEventCanonicalV1 bytes.
pub fn encode(value: &Value) -> Result<Vec<u8>, EncodeError> {
    let mut buf = Vec::new();
    encode_into(value, &mut buf, 0)?;
    Ok(buf)
}

fn encode_into(value: &Value, buf: &mut Vec<u8>, depth: usize) -> Result<(), EncodeError> {
    if depth > MAX_DEPTH {
        return Err(EncodeError::TooDeep);
    }
    match value {
        Value::Int(n) => {
            if *n >= 0 {
                write_head(buf, 0, *n as u64)?;
            } else {
                // CBOR negative: encodes -1 - n; for two's-complement i64 this
                // is the bitwise NOT of the u64 reinterpretation (no overflow,
                // including i64::MIN).
                write_head(buf, 1, !(*n as u64))?;
            }
        }
        Value::Text(s) => {
            write_head(buf, 3, s.len() as u64)?;
            write_bytes(buf, s.as_bytes())?;
        }
        Value::Bytes(b) => {
            write_head(buf, 2, b.len() as u64)?;
            write_bytes(buf, b)?;
        }
        Value::Bool(true) => write_bytes(buf, &[0xf5])?,
        Value::Bool(false) => write_bytes(buf, &[0xf4])?,
        Value::Null => write_bytes(buf, &[0xf6])?,
        Value::List(items) => {
            write_head(buf, 4, items.len() as u64)?;
            for item in items {
                encode_into(item, buf, depth + 1)?;
            }
        }
        Value::Map(pairs) => {
            // Encode each (key, value) pair separately, sort bytewise by the
            // encoded key (RFC 8949 §4.2.1), then emit.
            let mut encoded: Vec<(Vec<u8>, Vec<u8>)> = Vec::with_capacity(pairs.len());
            for (k, v) in pairs {
                let mut kbuf = Vec::new();
                write_head(&mut kbuf, 3, k.len() as u64)?;
                kbuf.extend_from_slice(k.as_bytes());
                let mut vbuf = Vec::new();
                encode_into(v, &mut vbuf, depth + 1)?;
                encoded.push((kbuf, vbuf));
            }
            encoded.sort_by(|a, b| a.0.cmp(&b.0));
            for w in encoded.windows(2) {
                if w[0].0 == w[1].0 {
                    return Err(EncodeError::DuplicateMapKey);
                }
            }
            write_head(buf, 5, encoded.len() as u64)?;
            for (kbuf, vbuf) in encoded {
                write_bytes(buf, &kbuf)?;
                write_bytes(buf, &vbuf)?;
            }
        }
    }
    Ok(())
}

/// Shortest-form (preferred) CBOR head: major type + argument.
fn write_head(buf: &mut Vec<u8>, major: u8, arg: u64) -> Result<(), EncodeError> {
    let mt = major << 5;
    if arg < 24 {
        write_bytes(buf, &[mt | arg as u8])
    } else if arg <= 0xff {
        write_bytes(buf, &[mt | 24, arg as u8])
    } else if arg <= 0xffff {
        let b = (arg as u16).to_be_bytes();
        write_bytes(buf, &[mt | 25, b[0], b[1]])
    } else if arg <= 0xffff_ffff {
        let b = (arg as u32).to_be_bytes();
        buf.push(mt | 26);
        write_bytes(buf, &b)
    } else {
        buf.push(mt | 27);
        write_bytes(buf, &arg.to_be_bytes())
    }
}

fn write_bytes(buf: &mut Vec<u8>, bytes: &[u8]) -> Result<(), EncodeError> {
    if buf.len() + bytes.len() > MAX_BYTES {
        return Err(EncodeError::TooLarge);
    }
    buf.extend_from_slice(bytes);
    Ok(())
}

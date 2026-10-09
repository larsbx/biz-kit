//! NIF layer for CoopEventCanonicalV1.
//!
//! Plain-NIF safe per hand-off §4: bounded input (size + depth caps enforced
//! in core), deterministic, no unbounded allocation. Conversion from BEAM
//! terms enforces the frozen profile in SUBSTRATE.md §1.

pub mod core;

use crate::core::{EncodeError, Value, MAX_DEPTH};
use rustler::dynamic::TermType;
use rustler::types::binary::{Binary, OwnedBinary};
use rustler::types::map::MapIterator;
use rustler::types::tuple::get_tuple;
use rustler::{Encoder, Env, Term};
use sha2::{Digest, Sha256};

mod atoms {
    rustler::atoms! {
        ok,
        error,
        float_forbidden,
        int_out_of_range,
        invalid_utf8,
        bad_map_key,
        forbidden_type,
        bad_bytes_wrapper,
        duplicate_map_key,
        too_large,
        too_deep,
    }
}

fn error_atom(e: EncodeError) -> rustler::types::atom::Atom {
    match e {
        EncodeError::FloatForbidden => atoms::float_forbidden(),
        EncodeError::IntOutOfRange => atoms::int_out_of_range(),
        EncodeError::InvalidUtf8 => atoms::invalid_utf8(),
        EncodeError::BadMapKey => atoms::bad_map_key(),
        EncodeError::ForbiddenType => atoms::forbidden_type(),
        EncodeError::BadBytesWrapper => atoms::bad_bytes_wrapper(),
        EncodeError::DuplicateMapKey => atoms::duplicate_map_key(),
        EncodeError::TooLarge => atoms::too_large(),
        EncodeError::TooDeep => atoms::too_deep(),
    }
}

fn term_to_value(term: Term, depth: usize) -> Result<Value, EncodeError> {
    if depth > MAX_DEPTH {
        return Err(EncodeError::TooDeep);
    }
    match term.get_type() {
        TermType::Integer => term
            .decode::<i64>()
            .map(Value::Int)
            .map_err(|_| EncodeError::IntOutOfRange),
        TermType::Float => Err(EncodeError::FloatForbidden),
        TermType::Atom => {
            let name = term
                .atom_to_string()
                .map_err(|_| EncodeError::ForbiddenType)?;
            match name.as_str() {
                "true" => Ok(Value::Bool(true)),
                "false" => Ok(Value::Bool(false)),
                "nil" => Ok(Value::Null),
                _ => Err(EncodeError::ForbiddenType),
            }
        }
        TermType::Binary => {
            let bin = term
                .decode::<Binary>()
                .map_err(|_| EncodeError::ForbiddenType)?;
            match std::str::from_utf8(bin.as_slice()) {
                Ok(s) => Ok(Value::Text(s.to_string())),
                Err(_) => Err(EncodeError::InvalidUtf8),
            }
        }
        TermType::List => {
            let mut items = Vec::new();
            let mut tail = term;
            while !tail.is_empty_list() {
                let (head, rest) = tail
                    .list_get_cell()
                    .map_err(|_| EncodeError::ForbiddenType)?;
                items.push(term_to_value(head, depth + 1)?);
                tail = rest;
            }
            Ok(Value::List(items))
        }
        TermType::Map => {
            let iter = MapIterator::new(term).ok_or(EncodeError::ForbiddenType)?;
            let mut pairs = Vec::new();
            for (k, v) in iter {
                if k.get_type() != TermType::Binary {
                    return Err(EncodeError::BadMapKey);
                }
                let kbin = k.decode::<Binary>().map_err(|_| EncodeError::BadMapKey)?;
                let ks = std::str::from_utf8(kbin.as_slice())
                    .map_err(|_| EncodeError::BadMapKey)?
                    .to_string();
                pairs.push((ks, term_to_value(v, depth + 1)?));
            }
            Ok(Value::Map(pairs))
        }
        TermType::Tuple => {
            let elems = get_tuple(term).map_err(|_| EncodeError::ForbiddenType)?;
            if elems.len() != 2 {
                return Err(EncodeError::ForbiddenType);
            }
            let tag = elems[0]
                .atom_to_string()
                .map_err(|_| EncodeError::ForbiddenType)?;
            if tag != "bytes" {
                return Err(EncodeError::ForbiddenType);
            }
            let bin = elems[1]
                .decode::<Binary>()
                .map_err(|_| EncodeError::BadBytesWrapper)?;
            Ok(Value::Bytes(bin.as_slice().to_vec()))
        }
        _ => Err(EncodeError::ForbiddenType),
    }
}

fn do_encode(term: Term) -> Result<Vec<u8>, EncodeError> {
    let value = term_to_value(term, 0)?;
    core::encode(&value)
}

fn bytes_to_binary<'a>(env: Env<'a>, bytes: &[u8]) -> Binary<'a> {
    let mut owned = OwnedBinary::new(bytes.len()).expect("binary allocation failed");
    owned.as_mut_slice().copy_from_slice(bytes);
    Binary::from_owned(owned, env)
}

#[rustler::nif]
fn nif_encode<'a>(env: Env<'a>, term: Term<'a>) -> Term<'a> {
    match do_encode(term) {
        Ok(bytes) => (atoms::ok(), bytes_to_binary(env, &bytes)).encode(env),
        Err(e) => (atoms::error(), error_atom(e)).encode(env),
    }
}

#[rustler::nif]
fn nif_hash<'a>(env: Env<'a>, term: Term<'a>) -> Term<'a> {
    match do_encode(term) {
        Ok(bytes) => {
            let digest = Sha256::digest(&bytes);
            (atoms::ok(), bytes_to_binary(env, &digest)).encode(env)
        }
        Err(e) => (atoms::error(), error_atom(e)).encode(env),
    }
}

rustler::init!("Elixir.CoopSubstrate.Canonical");

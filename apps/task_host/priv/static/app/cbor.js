// CoopEventCanonicalV1, the ledger's canonical encoding: a strict subset of
// deterministic CBOR (apps/coop_substrate/SUBSTRATE.md §1) with integers,
// text, byte strings, arrays, text-keyed maps, booleans and null.
// The browser decodes what it is asked to sign, so a person sees the command
// itself rather than the server's description of it. It encodes only what it
// builds itself: a governance-signed read (docs/architecture/2026-10-19-administration.md).
//
// Byte strings are {__bytes__: "<hex>"}; integers outside ±(2^53 - 1)
// BigInt. Anything outside the profile (tags, floats, indefinite lengths,
// trailing bytes) is refused.

export const hex = (bytes) => Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");

const SAFE = 2n ** 53n - 1n;
const text = new TextDecoder("utf-8", { fatal: true });

export function decode(bytes) {
  let pos = 0;

  const fail = (why) => {
    throw new Error(`not CoopEventCanonicalV1 at byte ${pos}: ${why}`);
  };

  const take = (n) => {
    if (pos + n > bytes.length) fail("truncated");
    const out = bytes.subarray(pos, pos + n);
    pos += n;
    return out;
  };

  const argument = (info) => {
    if (info < 24) return BigInt(info);
    const size = { 24: 1, 25: 2, 26: 4, 27: 8 }[info];
    if (!size) fail("indefinite or reserved length");
    return take(size).reduce((acc, b) => (acc << 8n) | BigInt(b), 0n);
  };

  const integer = (v) => (v >= -SAFE && v <= SAFE ? Number(v) : v);
  const length = (info) => Number(argument(info));

  const item = () => {
    const [initial] = take(1);
    const major = initial >> 5;
    const info = initial & 31;

    switch (major) {
      case 0:
        return integer(argument(info));
      case 1:
        return integer(-1n - argument(info));
      case 2:
        return { __bytes__: hex(take(length(info))) };
      case 3: {
        const raw = take(length(info));
        try {
          return text.decode(raw);
        } catch {
          return fail("invalid UTF-8");
        }
      }
      case 4:
        return Array.from({ length: length(info) }, () => item());
      case 5: {
        const map = {};
        for (let i = length(info); i > 0; i--) {
          const key = item();
          if (typeof key !== "string") fail("map key is not text");
          map[key] = item();
        }
        return map;
      }
      case 7:
        if (info === 20) return false;
        if (info === 21) return true;
        if (info === 22) return null;
        return fail("float or simple value");
      default:
        return fail("tag");
    }
  };

  const value = item();
  if (pos !== bytes.length) fail("trailing bytes");
  return value;
}

const utf8 = new TextEncoder();

// The canonical encoding of `value`: shortest-form heads, map keys sorted
// bytewise over their encodings.
export function encode(value) {
  const head = (major, n) => {
    n = BigInt(n);
    if (n < 24n) return [(major << 5) | Number(n)];
    const size = n < 256n ? 1 : n < 65536n ? 2 : n < 4294967296n ? 4 : 8;
    const out = [(major << 5) | { 1: 24, 2: 25, 4: 26, 8: 27 }[size]];
    for (let i = size - 1; i >= 0; i--) out.push(Number((n >> BigInt(8 * i)) & 255n));
    return out;
  };
  const concat = (parts) => Uint8Array.from(parts.flatMap((p) => Array.from(p)));
  const compare = (a, b) => {
    for (let i = 0; i < Math.min(a.length, b.length); i++) if (a[i] !== b[i]) return a[i] - b[i];
    return a.length - b.length;
  };

  const item = (v) => {
    if (v === null) return Uint8Array.of(0xf6);
    if (v === false) return Uint8Array.of(0xf4);
    if (v === true) return Uint8Array.of(0xf5);
    if (typeof v === "bigint" || Number.isInteger(v)) {
      const n = BigInt(v);
      return Uint8Array.from(n < 0n ? head(1, -1n - n) : head(0, n));
    }
    if (typeof v === "string") {
      const bytes = utf8.encode(v);
      return concat([head(3, bytes.length), bytes]);
    }
    if (Array.isArray(v)) return concat([head(4, v.length), ...v.map(item)]);
    if (typeof v === "object" && typeof v.__bytes__ === "string") {
      const bytes = Uint8Array.from(v.__bytes__.match(/../g) ?? [], (b) => parseInt(b, 16));
      return concat([head(2, bytes.length), bytes]);
    }
    if (typeof v === "object") {
      const entries = Object.entries(v)
        .map(([k, x]) => [item(k), item(x)])
        .sort(([a], [b]) => compare(a, b));
      return concat([head(5, entries.length), ...entries.flat()]);
    }
    throw new Error(`not representable in CoopEventCanonicalV1: ${typeof v}`);
  };

  return item(value);
}

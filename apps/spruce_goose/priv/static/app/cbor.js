// Decoder for CoopEventCanonicalV1, the ledger's canonical encoding: a strict
// subset of deterministic CBOR (apps/coop_substrate/SUBSTRATE.md §1) with
// integers, text, byte strings, arrays, text-keyed maps, booleans and null.
// The browser decodes what it is asked to sign, so a person sees the command
// itself rather than the server's description of it.
//
// Byte strings decode as {__bytes__: "<hex>"}; integers outside ±(2^53 - 1)
// as BigInt. Anything outside the profile (tags, floats, indefinite lengths,
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

/**
 * Identity — how a caller's key becomes the partition its rows live in.
 *
 * The app generates 32 random bytes on first use, keeps them in the Keychain and sends them as
 * `X-Whoopsy-User-Id` on every request. This Worker **never stores that value**. It stores
 * `sha256(key)` and scopes every query by the digest, which is the whole point of the file: a D1 dump
 * is then a set of anonymous partitions rather than a list of working credentials. The stored value
 * cannot be replayed as a header, because the header is hashed again on the way in and the two
 * digests are of different strings.
 *
 * **This does not authenticate anybody, and the token step does not change that.** The gate in
 * `utils/tokens.ts` decides whether a request may be served at all; this file decides *which
 * partition* it is served from, and it verifies nothing — anyone can mint a key, and a key that is
 * guessed is a partition that is read, which is exactly what being a bearer credential means. What
 * the digest buys is the blast radius of a database leak, not the integrity of a request.
 * `dto/shared.ts` carries the consequences in the header schema's own description.
 *
 * The hash is unsalted and unstretched on purpose. A salt would have to live beside the database it
 * protects, so it would leak with it and buy nothing; a KDF would be right for a human-chosen
 * password and is pointless for 32 bytes of `SecRandomCopyBytes`, where there is no dictionary to
 * search. What makes the digest safe to store is the entropy of its input, and that is a claim about
 * the *client* — which is why `MIN_KEY_LENGTH` below is a floor on the encoding and no more.
 */

/**
 * The shortest key this Worker will accept, in characters.
 *
 * 32 random bytes encode to 43 base64url characters or 64 hex ones, so the real client's key clears
 * this by a wide margin. The floor exists for the caller that is *not* the real client: without it a
 * one-character header is a valid partition, and every short header anybody ever fat-fingers
 * collapses onto the same handful of rows. It is a length test and cannot be more than one — this
 * Worker has no way to measure the entropy of a string, only to refuse one that is obviously too
 * short to hold 32 bytes at any encoding.
 *
 * A key shorter than this is refused as `400 invalid_request` by the header schema, before any
 * handler runs.
 */
export const MIN_KEY_LENGTH = 32;

/**
 * The longest key this Worker will accept, in characters.
 *
 * A bound rather than a security measure: the header is attacker-controlled and goes into a hashing
 * call, so an unbounded one is a way to make every request allocate. 200 is the value the header
 * schema has always used and is far above the 43 a real key needs.
 */
export const MAX_KEY_LENGTH = 200;

/**
 * Whether a header value may be used as a key at all.
 *
 * Exported so the schema and this file cannot disagree about the rule, and so the boundary is
 * assertable without constructing a `Request`.
 */
export function isUsableKey(key: string): boolean {
  return key.length >= MIN_KEY_LENGTH && key.length <= MAX_KEY_LENGTH;
}

/**
 * The Worker's digest primitive: SHA-256 of a string, as raw bytes.
 *
 * It lives here because this file is where the hashing rule is argued, and it is exported because a
 * second caller exists — `utils/tokens.ts` hashes both sides of the token comparison so that
 * `timingSafeEqual` is handed two equal-length inputs. That caller wants the **bytes** and this file
 * wants a hex **string**, which is why the digest is the exported thing and `toHex` is not: a
 * security-relevant primitive written out twice is a primitive that can be changed in one place.
 *
 * `crypto.subtle` rather than `node:crypto`, because this is the Worker's own runtime primitive and
 * the `nodejs_compat` flag is declared for the test pool's sake rather than for `src/`'s — nothing
 * here should start depending on it. `digest` is async, which is why identity derivation is an
 * `await` at the call site rather than a pure expression.
 */
export async function sha256(value: string): Promise<Uint8Array> {
  const bytes = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest("SHA-256", bytes);

  return new Uint8Array(digest);
}

/**
 * The partition a key's rows live under: `sha256(key)`, lowercase hex.
 *
 * Lowercase hex and not base64: the value is a database column that a human will occasionally read
 * out of `wrangler d1 execute` while debugging, and one canonical spelling of it is worth more than
 * four bytes of width.
 */
export async function deriveUserId(key: string): Promise<string> {
  return toHex(await sha256(key));
}

/**
 * Lowercase hex.
 *
 * `forEach` rather than a `for` loop over indices, and rather than `for…of`. `for…of` needs the
 * downlevel iteration lib that the Worker's types omit; an indexed `bytes[index]` reads as
 * `number | undefined` under `noUncheckedIndexedAccess`, which would make every digit here a
 * `!` or an impossible-looking guard. The callback parameter is a plain `number`, and the read is in
 * bounds by construction, so this is the one spelling with neither a hole nor an assertion in it.
 */
function toHex(bytes: Uint8Array): string {
  let hex = "";
  bytes.forEach((byte) => {
    hex += byte.toString(16).padStart(2, "0");
  });
  return hex;
}

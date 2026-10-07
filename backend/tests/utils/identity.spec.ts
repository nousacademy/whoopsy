import { SELF, env } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { authHeaders } from "../Support/auth";
import {
  deriveUserId,
  isUsableKey,
  MAX_KEY_LENGTH,
  MIN_KEY_LENGTH,
} from "../../src/utils/identity";

/**
 * How a key becomes a partition, asserted against values that did not come from this code.
 *
 * This file exists because `tests/routes/recoveries.spec.ts` deliberately computes its handle on a
 * partition *with* `deriveUserId` — it needs the two sides to agree about which rows they are
 * talking about, and an independent implementation there would be a second thing that could be
 * wrong. The cost of that choice is that the derivation itself is never pinned in that file: every
 * count there would still pass if `deriveUserId` returned the key unchanged, because the same
 * function would compute both sides. **This is where that is answered**, and it is answered the way
 * this repo answers it everywhere — with an expected value from outside the code under test.
 *
 * The digests below were computed with `shasum -a 256`, which is not Swift, not TypeScript and not
 * this Worker. One of them is the SHA-256 of the empty string, which is a published constant and can
 * be checked against any reference in any language. That is the CRC-vector rule as it applies here:
 * an assertion whose expected value is computed by the code under test proves that the code is
 * self-consistent, and nothing more.
 */

const BASE = "https://whoopsy.test";

/** Two real keys at the length the app sends, sharing a prefix on purpose — see the last block. */
const KEY = "Zx8Vq2LmNp4Rt7Yw3Bc6Df9Gh1Jk5Mn0Pq2Rs4Tu6Vw";
const NEIGHBOUR = "Zx8Vq2LmNp4Rt7Yw3Bc6Df9Gh1Jk5Mn0Pq2Rs4Tu6Vx";

/**
 * `sha256`, lowercase hex, computed by `shasum -a 256` outside this repository.
 *
 * The empty string is first and it is the one that matters most, because it is the only vector here
 * a reader can verify without trusting this file: `e3b0c442…b855` is what every reference
 * implementation answers for `sha256("")`, so if it matches, the algorithm, the input encoding and
 * the hex conversion are all what this file claims — and if it does not, the two 43-character
 * digests below being internally consistent would prove nothing.
 *
 * The second is the key a `PUT` in this file is sent under. The third is its neighbour, one
 * character different at the end, for the collision block.
 */
const DIGESTS: readonly (readonly [key: string, digest: string])[] = [
  ["", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"],
  [KEY, "11bd93e4744735e9c1d01247ecacd176034d5814be4fc7aa4b24b948b68c4f9d"],
  [NEIGHBOUR, "52cd96ef88a5abe8778268e79d532dafc0d23b822293ea7d89aea1d721f6aed3"],
];

function read(path: string, key: string): Promise<Response> {
  return SELF.fetch(`${BASE}${path}`, { headers: { ...authHeaders(key) } });
}

function put(key: string): Promise<Response> {
  return SELF.fetch(`${BASE}/v1/recoveries/2026-08-22`, {
    method: "PUT",
    headers: { "content-type": "application/json", ...authHeaders(key) },
    body: JSON.stringify({
      recoveryScore: 68,
      restingHeartRate: 52,
      hrvValueMs: 71.4,
      hrvMetric: "rmssd",
      skinTemperature: null,
      spo2Percentage: null,
      respiratoryRate: null,
      source: null,
    }),
  });
}

describe("the partition a key maps to", () => {
  it("is sha256 of the key, in lowercase hex, pinned against digests computed elsewhere", async () => {
    for (const [key, digest] of DIGESTS) {
      expect(await deriveUserId(key)).toBe(digest);
    }
  });

  it("is always 64 characters, over a spread of keys that includes small bytes", async () => {
    for (const [key] of DIGESTS) {
      const partition = await deriveUserId(key);

      // The length is not implied by the digest above and it is the assertion that catches a
      // `toString(16)` with a missing `padStart("0")`: a byte below `0x10` renders as one character,
      // so the digest would come out *shorter* and different on every key that happens to contain
      // one — a variable-length column that still looks like hex and still partitions consistently,
      // which is exactly the kind of defect that survives to production. `shasum` pads, so these
      // pinned values would fail the moment this one stopped.
      expect(partition).toMatch(/^[0-9a-f]{64}$/);
    }
  });

  it("is stable across calls and different for every distinct key", async () => {
    expect(await deriveUserId(KEY)).toBe(await deriveUserId(KEY));

    // One character. A key and its neighbour are the same partition under anything that hashes a
    // prefix, a length, or a truncated digest — and a collision there is two installs sharing rows
    // with nothing anywhere reporting it.
    expect(await deriveUserId(KEY)).not.toBe(await deriveUserId(NEIGHBOUR));

    // Case is a difference, not a normalisation: base64url is case-sensitive, so these are two keys
    // and must not collapse. `toLowerCase()` anywhere in the derivation would make them one — and
    // would also make the column's values shorter than the hex above, which the length assertion
    // would catch for a different reason.
    expect(await deriveUserId(KEY)).not.toBe(await deriveUserId(KEY.toLowerCase()));
  });
});

describe("the key guard", () => {
  it("is a closed interval, pinned one character either side of both edges", () => {
    // `isUsableKey` directly, because that is the rule the header schema and `routes/recoveries.ts`
    // both reach through — and because a boundary expressed as a length test has exactly one
    // realistic defect, an off-by-one, which a test of the middle of the interval cannot see.
    expect(isUsableKey("a".repeat(MIN_KEY_LENGTH - 1))).toBe(false);
    expect(isUsableKey("a".repeat(MIN_KEY_LENGTH))).toBe(true);

    expect(isUsableKey("a".repeat(MAX_KEY_LENGTH))).toBe(true);
    expect(isUsableKey("a".repeat(MAX_KEY_LENGTH + 1))).toBe(false);

    // And the empty key, which is the shortest unusable one and the value a client sends when it
    // means "no key" but spells it as a header.
    expect(isUsableKey("")).toBe(false);
  });

  it("is the same rule the header schema enforces, at all four edges", async () => {
    // The pure function above and the wire cannot drift: `UserHeaderSchema` is built from these two
    // constants, so a schema that hardcoded 8 — which the fixtures in `routes/recoveries.spec.ts`
    // would never notice, since they are all longer than either — is caught here and only here.
    const tooShort = await read("/v1/recoveries/2026-08-22", "a".repeat(MIN_KEY_LENGTH - 1));
    expect(tooShort.status).toBe(400);

    // 404 rather than 200: the request got as far as the partition and found no row, which is what
    // "accepted" looks like on a day nobody has written.
    const shortest = await read("/v1/recoveries/2026-08-22", "a".repeat(MIN_KEY_LENGTH));
    expect(shortest.status).toBe(404);

    const longest = await read("/v1/recoveries/2026-08-22", "a".repeat(MAX_KEY_LENGTH));
    expect(longest.status).toBe(404);

    const tooLong = await read("/v1/recoveries/2026-08-22", "a".repeat(MAX_KEY_LENGTH + 1));
    expect(tooLong.status).toBe(400);
  });
});

describe("the user_id column", () => {
  it("holds the digest for a row that arrived through the router", async () => {
    expect((await put(KEY)).status).toBe(200);

    const stored = await env.DB.prepare("SELECT user_id FROM recoveries")
      .first<{ user_id: string }>();

    // Read back rather than assumed from the fact that the request worked: a `user_id` equal to the
    // key would satisfy every endpoint in this Worker, because the same string would be hashed on
    // the way in and matched on the way out. The only thing that separates the two is looking at
    // the column, and what is at stake is whether a database dump is a set of anonymous partitions
    // or a list of working credentials.
    expect(stored?.user_id).toBe(DIGESTS[1]![1]);
    expect(stored?.user_id).not.toBe(KEY);
  });

  it("keeps a shared prefix from being a shared partition", async () => {
    await put(KEY);

    // The sharpest version of the isolation rule, because `KEY` and `NEIGHBOUR` differ only in their
    // last character: a partition derived from a prefix, a count, or anything but the whole key would
    // put the second caller's read on the first caller's row.
    expect((await read("/v1/recoveries/2026-08-22", KEY)).status).toBe(200);
    expect((await read("/v1/recoveries/2026-08-22", NEIGHBOUR)).status).toBe(404);

    const list = await read("/v1/recoveries?days=2&endingOn=2026-08-22", NEIGHBOUR);
    expect(await list.json()).toEqual([]);
  });
});

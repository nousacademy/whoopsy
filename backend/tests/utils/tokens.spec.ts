import { describe, expect, it } from "vitest";
import { bearerToken, MIN_TOKEN_LENGTH, tokensMatch } from "../../src/utils/tokens";

/**
 * The two pure functions behind the gate.
 *
 * **No `Request` is constructed here, and that is the split this file is half of.** What a *request*
 * carrying a good or bad credential does — the status, the envelope, the order the gate runs in — is
 * `tests/app.spec.ts`, which drives the real Worker. What is asserted here is the parsing and the
 * comparison on their own, because both have boundaries that are hard to reach through the wire and
 * easy to get wrong: a scheme spelled in three cases, one space against two, and the length
 * mismatch that `timingSafeEqual` throws on.
 */

describe("bearerToken", () => {
  it("reads a well-formed header", () => {
    expect(bearerToken("Bearer abc123")).toBe("abc123");
  });

  it("accepts the scheme in any case, because RFC 7235 says it is case-insensitive", () => {
    // The scheme is case-insensitive and the credential is not — so these are three spellings of one
    // header, and the *token* below is deliberately identical in all three. A client that lowercases
    // the scheme is not making a mistake worth a 401.
    expect(bearerToken("bearer abc123")).toBe("abc123");
    expect(bearerToken("BEARER abc123")).toBe("abc123");
    expect(bearerToken("BeArEr abc123")).toBe("abc123");

    // And case is a difference in the credential itself, not a normalisation — a gate that
    // lowercased the token would accept a second value for every secret.
    expect(bearerToken("Bearer ABC123")).toBe("ABC123");
  });

  it("refuses a bare token, because a scheme is required", () => {
    // Accepting this would mean guessing which scheme the caller meant, and there is exactly one this
    // Worker accepts.
    expect(bearerToken("abc123")).toBeNull();
  });

  it("refuses a scheme with no credential, and a credential with no scheme", () => {
    expect(bearerToken("Bearer")).toBeNull();
    expect(bearerToken("Bearer ")).toBeNull();
    expect(bearerToken(" ")).toBeNull();
  });

  it("refuses exactly two spaces, and this is the boundary worth pinning", () => {
    // The fetch `Headers` object strips *outer* whitespace before this ever runs, so the space this
    // decides about is the interior one a client controls. One is the spelling; two is a header built
    // by concatenation, and the honest answer is `null` rather than a lenient parse that would make
    // this Worker accept a spelling no other one does.
    expect(bearerToken("Bearer  abc123")).toBeNull();
  });

  it("refuses another scheme outright", () => {
    // Not trimmed to its credential: `Basic` credentials are a different thing entirely, and a gate
    // that read one as the other would be comparing a base64 pair against a secret.
    expect(bearerToken("Basic abc123")).toBeNull();
  });

  it("refuses a credential containing a space", () => {
    expect(bearerToken("Bearer abc 123")).toBeNull();
  });

  it("returns null for an absent header", () => {
    expect(bearerToken(undefined)).toBeNull();
  });

  it("is stateless across calls", () => {
    // The `g` flag on a regex literal carries `lastIndex` between calls, so a module-level global
    // regex would answer differently on the second request than on the first — a bug that appears
    // only under load. Calling the same input twice is the whole of the test.
    expect(bearerToken("Bearer abc123")).toBe("abc123");
    expect(bearerToken("Bearer abc123")).toBe("abc123");
  });
});

describe("tokensMatch", () => {
  it("accepts the same string and refuses a different one", async () => {
    expect(await tokensMatch("s3cret", "s3cret")).toBe(true);
    expect(await tokensMatch("s3cret", "s3cres")).toBe(false);
  });

  it("refuses a one-character difference anywhere, including at the ends", async () => {
    const token = "abcdefghij";

    expect(await tokensMatch(token, `${token}x`)).toBe(false);
    expect(await tokensMatch(token, `x${token}`)).toBe(false);
    expect(await tokensMatch(token, "abcdefghiJ")).toBe(false);
  });

  it("answers false rather than throwing when the lengths differ", async () => {
    // **This is the assertion that pins the hash-both-sides decision.** `crypto.subtle.timingSafeEqual`
    // is constant-time only for equal-length inputs and *throws* on inputs that differ in length —
    // and the presented value is attacker-controlled while the secret's length is the operator's, so
    // a direct comparison would either crash the request or leak the secret's length through the
    // difference in behaviour between a short guess and a long one. Hashing both sides first maps
    // them to 32 bytes whatever they were.
    //
    // If anyone ever "simplifies" `tokensMatch` to compare the strings directly, this test is what
    // fails — and it fails on the *short* case, which is the one an attacker sends first.
    await expect(tokensMatch("", "s3cret")).resolves.toBe(false);
    await expect(tokensMatch("s3cret", "")).resolves.toBe(false);
    await expect(tokensMatch("a", "a".repeat(1000))).resolves.toBe(false);
    await expect(tokensMatch("a".repeat(1000), "a")).resolves.toBe(false);
  });

  it("treats the empty string as a value like any other", async () => {
    expect(await tokensMatch("", "")).toBe(true);
  });

  it("refuses a case variant, because a secret is compared byte for byte", async () => {
    expect(await tokensMatch("S3CRET", "s3cret")).toBe(false);
  });

  it("accepts a token at the published floor and above", async () => {
    // `MIN_TOKEN_LENGTH` is a property of the *configuration* rather than of this comparison — a
    // short configured secret is refused by `createApp` before this is ever called — so what is worth
    // asserting here is only that the comparison itself has no opinion about length.
    const atFloor = "a".repeat(MIN_TOKEN_LENGTH);

    expect(await tokensMatch(atFloor, atFloor)).toBe(true);
  });
});

/**
 * The deployment's shared secret, and the two pure functions that decide whether a request carries it.
 *
 * **This is the gate, and it is a speed bump rather than an identity.** One secret is configured for
 * the whole deployment and every client sends the same one, so the token says "this caller knows the
 * string the operator published to their own app" and nothing more. It is what stops a scanner, a bot
 * or a drive-by request against a discoverable `*.workers.dev` hostname. It does **not** distinguish
 * one install from another, cannot be revoked per device, and is extractable from the app binary it
 * ships in. Per-install identity is a different design — an `accounts` table with issued credentials —
 * and it is not this file.
 *
 * The secret belongs to the deployment and never to this repository: nothing in the tree carries one,
 * both `backend/.dev.vars` and the iOS `.local.xcconfig` are gitignored, and two deployments have two
 * unrelated secrets that can read neither's rows.
 *
 * Both functions are pure so the boundary is assertable without constructing a `Request` — the wire
 * behaviour is covered separately, in `tests/app.spec.ts`.
 */

import { sha256 } from "./identity";

/**
 * The shortest secret this Worker will serve under, in characters.
 *
 * **Its own constant, deliberately, and not a reuse of `identity.ts`'s `MIN_KEY_LENGTH`.** The two
 * bound different things: `MIN_KEY_LENGTH` bounds a request *header* that a caller controls, while
 * this bounds a *deployment secret* the operator chooses once. Sharing the number would tie a change
 * to one rule to a rule about the other, and the two would then be argued about together.
 *
 * 32 characters is the same floor for the same reason — it is where a base64 encoding of 24 bytes
 * starts, and below it a guessable secret is the only kind available. The README's `openssl rand
 * -base64 32` clears it four times over. A secret shorter than this is treated as **not configured**
 * rather than as a weak one: see `createApp`'s gate for why the answer to an unarmed Worker is a 500
 * and not a 401.
 */
export const MIN_TOKEN_LENGTH = 32;

/**
 * The token out of an `Authorization` header, or `null` if the header does not carry one.
 *
 * **The scheme is required and the spelling of it is not.** RFC 7235 makes the scheme
 * case-insensitive, so `Bearer`, `bearer` and `BEARER` all name the same thing, and a client that
 * sends one of the other two is not making a mistake worth a refusal. A bare token with no scheme is
 * refused: accepting it would mean this Worker guesses which of the several schemes the caller meant,
 * and there is exactly one it accepts.
 *
 * **Exactly one space.** `Bearer  x` is refused rather than trimmed. The fetch `Headers` object has
 * already stripped the outer whitespace from the value, so what is left here is the interior kind,
 * and it is a spelling the client controls — a second space is a client that built the header by
 * concatenation without thinking about it, and the honest answer is `null` rather than a lenient
 * parse that would make this Worker accept spellings no other one does.
 *
 * **No `g` flag, and that is not a style note.** A `g`-flagged regex literal carries `lastIndex`
 * across calls, so a module-level one would answer differently on the second request than on the
 * first — a bug that appears only under load and only for some callers.
 */
export function bearerToken(header: string | undefined): string | null {
  if (header === undefined) return null;

  const match = /^Bearer ([^\s]+)$/i.exec(header);

  return match?.[1] ?? null;
}

/**
 * Whether the presented token is the configured one, in constant time.
 *
 * **Both sides are hashed first, and that is the mechanism rather than a formality.**
 * `crypto.subtle.timingSafeEqual` is constant-time only for inputs of equal length and *throws* on
 * inputs that differ in length — so comparing the two strings directly would leak the secret's length
 * through that throw, on a value the caller controls and the operator does not. SHA-256 maps both to
 * 32 bytes whatever they were, which makes the comparison well-defined for any presented input and
 * removes length from what the timing depends on. The digest is of no use to an attacker here: it is
 * computed in memory, never stored and never returned.
 *
 * (`timingSafeEqual` is synchronous — it returns a `boolean` — so only the two digests are awaited.)
 *
 * What a timing attack would buy against this endpoint is small, since the secret is long and random
 * and the endpoint is not a password form. The reason to do it anyway is that a comparison against a
 * secret is exactly the kind of code that gets copied somewhere it matters more.
 */
export async function tokensMatch(presented: string, configured: string): Promise<boolean> {
  const [presentedDigest, configuredDigest] = await Promise.all([
    sha256(presented),
    sha256(configured),
  ]);

  return crypto.subtle.timingSafeEqual(presentedDigest, configuredDigest);
}

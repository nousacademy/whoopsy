import { SELF, env } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { createApp } from "../src/app";
import { TEST_API_TOKEN, authHeaders } from "./Support/auth";

/**
 * The gate, on the wire.
 *
 * `tests/utils/tokens.spec.ts` pins the parsing and the comparison as pure functions; this file is
 * the other half — what the Worker actually answers, in what order, and with which body. The split
 * matters because most of what can go wrong here is not in either function. It is in whether the
 * middleware runs at all, whether it runs *before* the route it is protecting, and whether an
 * unarmed deployment says something different from a refused caller.
 *
 * **This file has no counterpart in `src/`, and it is not at `tests/<something>.spec.ts` by
 * accident.** The rule `vitest.config.ts` states is that a spec sits at its source file's own path;
 * `src/app.ts` is the file, so this is that spec — and the app is the one thing in this Worker whose
 * behaviour is a property of the whole composition rather than of any route. `tests/routes/*` covers
 * each resource through this same app; what is asserted here is the layer they all sit behind.
 *
 * **The messages and codes below are written out rather than imported.** A spec that compared the
 * body against `apiError("unauthorized", …)` would pass whatever that helper returned, including a
 * changed envelope — and the envelope is a published promise (`ErrorSchema`), not an implementation
 * detail.
 */

const BASE = "https://whoopsy.test";
const USER = "K7fQ2mZx9pLr4Tn6WvB1yHs8JcE3uGa5DkRm0Xq4YAb";

/**
 * The identity header and **no credential** — which is the whole point of the cases that use it.
 *
 * `authHeaders()` returns both, so reaching for it here would make every "unauthenticated" test below
 * send a perfectly good token and assert against a `200`. That mistake is not hypothetical: it is
 * what this file did first, and it produced five green-looking failures whose messages named the
 * status rather than the fixture.
 */
const IDENTITY_ONLY: Record<string, string> = { "x-whoopsy-user-id": USER };

/** The window route, read-only, so nothing below writes a row it would then have to reason about. */
const WINDOW = "/v1/recoveries?days=2&endingOn=2026-08-22";

function read(init: RequestInit = {}): Promise<Response> {
  return SELF.fetch(`${BASE}${WINDOW}`, init);
}

describe("the gate refuses a request without a usable credential", () => {
  it("answers 401 in the shared envelope when no Authorization header is sent", async () => {
    const response = await read({ headers: { ...IDENTITY_ONLY } });

    // The identity header is present and valid; the *credential* is not. So the gate is what refuses,
    // and this is the case a client hits when it has a key but has not been configured with a token.
    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({
      error: {
        code: "unauthorized",
        message:
          "the Authorization: Bearer credential is missing, or it does not match the one this deployment accepts",
      },
    });
  });

  it("answers the same 401 for a wrong credential as for an absent one", async () => {
    // One message for both, deliberately: telling them apart is an oracle this API has no reason to
    // publish, and a client has nothing useful to do with the difference.
    const absent = await read({ headers: { ...IDENTITY_ONLY } });
    const wrong = await read({
      headers: { ...IDENTITY_ONLY, authorization: "Bearer not-the-token-at-all-nope-nope" },
    });

    expect(wrong.status).toBe(401);
    expect(await wrong.json()).toEqual(await absent.json());
  });

  it("answers 401 for a credential one character off", async () => {
    // The boundary that separates a comparison from a prefix match. A gate built on `startsWith`, or
    // on a truncated digest, would admit this one and refuse nothing else here.
    const response = await read({
      headers: { ...IDENTITY_ONLY, authorization: `Bearer ${TEST_API_TOKEN.slice(0, -1)}` },
    });

    expect(response.status).toBe(401);
    expect((await response.json() as { error: { code: string } }).error.code).toBe("unauthorized");
  });

  it("answers 401 for a malformed header, including a bare token", async () => {
    for (const authorization of [
      TEST_API_TOKEN, // no scheme
      `Basic ${TEST_API_TOKEN}`, // the wrong scheme
      `Bearer  ${TEST_API_TOKEN}`, // two spaces
      "Bearer", // no credential
    ]) {
      const response = await read({ headers: { ...IDENTITY_ONLY, authorization } });

      expect(response.status, `accepted "${authorization}"`).toBe(401);
    }
  });

  it("runs the route once the credential is right, and accepts any case of the scheme", async () => {
    // The positive control for everything above: without it, a gate that refused *every* request
    // would satisfy this whole file. `bearer` in lowercase because the acceptance is the property
    // being added here — RFC 7235's case-insensitivity reaching the wire rather than only the parser.
    for (const authorization of [`Bearer ${TEST_API_TOKEN}`, `bearer ${TEST_API_TOKEN}`]) {
      const response = await read({ headers: { ...authHeaders(USER), authorization } });

      // **A `200` holding an empty array, not a 404** — the window read is the one route in this
      // Worker where "nothing measured" is a successful answer rather than an absence, which is the
      // rule `dto/recoveries.ts` argues for. It is also the assertion that separates "the gate let
      // this through and the route ran" from "something answered 200 without asking anyone": a 200
      // here is only reachable *past* the gate.
      expect(response.status, `refused "${authorization}"`).toBe(200);
      expect(await response.json()).toEqual([]);
    }
  });
});

describe("the gate runs before everything else", () => {
  it("refuses an unauthenticated request before the query is validated", async () => {
    // **The ordering assertion, and the one that would catch the middleware being registered after
    // `.route()`.** `days=not-a-number` fails validation with a 400 — so if the gate sat behind the
    // route it protects, this request would come back `400 invalid_request` and every other test in
    // this file would still pass. `src/app.ts` argues why the position is load-bearing rather than
    // tidy; this is what observes it.
    const response = await SELF.fetch(`${BASE}/v1/recoveries?days=not-a-number`, {
      headers: { ...IDENTITY_ONLY },
    });

    expect(response.status).toBe(401);
    expect((await response.json() as { error: { code: string } }).error.code).toBe("unauthorized");
  });

  it("refuses an unauthenticated request to a path that is not a route", async () => {
    // The fail-closed half of `OPEN_PATHS`. A caller with no credential learns only that they were
    // refused — not whether `/v1/nothing-here` is a route, because a `404` and a `401` would answer
    // that question for them. This is the deliberate consequence of `use("*")` over `use("/v1/*")`.
    const response = await SELF.fetch(`${BASE}/v1/nothing-here`);

    expect(response.status).toBe(401);
  });

  it("answers 404 for an unmatched path once the credential is right", async () => {
    // And the other side of it: an admitted caller gets the ordinary 404 in the shared envelope, so
    // the gate has not swallowed the route table's own answer.
    const response = await SELF.fetch(`${BASE}/v1/nothing-here`, {
      headers: { ...authHeaders() },
    });

    expect(response.status).toBe(404);
    expect(await response.json()).toEqual({
      error: { code: "route_not_found", message: "no route for GET /v1/nothing-here" },
    });
  });

  it("leaves the two open paths reachable with no credential at all", async () => {
    // `OPEN_PATHS`, and every assertion here is credential-free on purpose. `/health` is a liveness
    // probe: one that needed a secret would be a probe a monitor cannot run, and one that *reported*
    // whether the gate was armed would tell a stranger which Workers are worth attacking — so the
    // body is asserted exactly, and it names no token.
    const health = await SELF.fetch(`${BASE}/health`);
    expect(health.status).toBe(200);
    expect(await health.json()).toEqual({
      status: "ok",
      service: "whoopsy-sync",
      bindings: { db: true, exports: true },
    });

    // `/openapi.json` is the served contract. It is exempt because it is infrastructure rather than
    // API — and because the shell gate in `README.md` compares it against `shared/openapi.json` with
    // a curl that has no token to send.
    const document = await SELF.fetch(`${BASE}/openapi.json`);
    expect(document.status).toBe(200);
  });

  it("does not exempt a path that merely begins with an exempt one", async () => {
    // The exemption is matched with `===` on the path, not by prefix. A `startsWith` would exempt
    // every path under `/health`, which is a hole that grows silently the day someone mounts a
    // resource there.
    const response = await SELF.fetch(`${BASE}/health-secret`);

    expect(response.status).toBe(401);
  });
});

describe("a deployment with no secret configured", () => {
  it("answers 500 rather than 401, and does not pretend the caller was at fault", async () => {
    // **The unarmed arm, and it is a 500 on purpose.** `SYNC_API_TOKEN` absent, empty or shorter than
    // the floor is the operator's problem, not the caller's: answering 401 would say "your credential
    // is wrong" about a Worker that has none, to a human holding a curl and checking their spelling.
    // It also collapses the distinction this repo keeps between a caller's mistake and a Worker bug —
    // and it would make the *unarmed* case indistinguishable from the ordinary refusal above, which
    // is the one thing an operator needs to be able to tell apart.
    //
    // `createApp()` is built here rather than driven through `SELF`, because `SELF` is bound to the
    // configured runtime and there is no way to un-configure it. The factory exists for exactly this
    // — its own doc comment says a test can build its own app — and the `env` object below satisfies
    // `Env` while omitting the one binding that is optional.
    //
    // `DB` and `EXPORTS` are the real ones: nothing here reaches them, but a *missing* secret must be
    // the only reason this request fails, or the test would pass for the wrong reason.
    const unarmed = createApp();

    const response = await unarmed.request(
      `${BASE}${WINDOW}`,
      { headers: { ...IDENTITY_ONLY } },
      { DB: env.DB, EXPORTS: env.EXPORTS },
    );

    expect(response.status).toBe(500);
    expect(await response.json()).toEqual({
      error: {
        code: "internal_error",
        message: "the request could not be completed; the detail is in the worker logs",
      },
    });
  });

  it("treats a too-short secret as no secret at all rather than as a weak one", async () => {
    // A one-character secret is not a weaker gate, it is an unarmed one that would *look* armed — a
    // deployment that answers 200 to `Authorization: Bearer a` and reports itself as configured. The
    // floor is what makes "configured" mean something.
    const unarmed = createApp();

    const response = await unarmed.request(
      `${BASE}${WINDOW}`,
      { headers: { authorization: "Bearer a", "x-whoopsy-user-id": USER } },
      { DB: env.DB, EXPORTS: env.EXPORTS, SYNC_API_TOKEN: "a" },
    );

    expect(response.status).toBe(500);
  });

  it("still serves its two open paths while unarmed, because neither reads the binding", async () => {
    // A liveness probe that failed on an unconfigured Worker would report the Worker as down while it
    // is running perfectly well, which is the one thing a probe must not do.
    const unarmed = createApp();

    const response = await unarmed.request(
      `${BASE}/health`,
      {},
      { DB: env.DB, EXPORTS: env.EXPORTS },
    );

    expect(response.status).toBe(200);
  });
});

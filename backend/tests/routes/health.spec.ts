import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { SERVICE_NAME } from "../../src/openapi";

/**
 * `GET /health`, and the shape of a path that is not a route.
 *
 * Two claims are being made here and they are different claims: that the Worker answers at all
 * (which is what a liveness probe is for), and that the isolate was handed bindings of the kind the
 * code will call methods on. The second is why `bindings` is asserted `true` outright rather than
 * merely present — the route reports a *shape* test, so a `wrangler.toml` block pointed at the
 * wrong resource should show up as a `false` here rather than as a failure three endpoints later.
 *
 * **Nothing here asserts that D1 is reachable, because the endpoint does not ask.** That is the
 * route's decision and it is argued at its definition; this file would be the place it broke.
 */

const BASE = "https://whoopsy.test";

describe("GET /health", () => {
  it("answers while the Worker is running, naming itself and its bindings", async () => {
    const response = await SELF.fetch(`${BASE}/health`);

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      status: "ok",
      service: SERVICE_NAME,
      bindings: { db: true, exports: true },
    });
  });

  it("names the Worker the same thing wrangler.toml does", async () => {
    // The literal is deliberate and not a restatement of the import: `SERVICE_NAME` is what
    // `wrangler.toml`'s `name` is supposed to be, and a rename that reached the manifest and missed
    // this module would otherwise be invisible — the response and the constant would agree with
    // each other while both disagreed with the deployed Worker's own name.
    const response = await SELF.fetch(`${BASE}/health`);
    const body = (await response.json()) as { service: string };

    expect(body.service).toBe("whoopsy-sync");
  });
});

describe("an unmatched path", () => {
  it("is a 404 in the shared error envelope, not Hono's bare text default", async () => {
    const response = await SELF.fetch(`${BASE}/v1/nothing-here`, {
      headers: { "x-whoopsy-user-id": "test" },
    });

    expect(response.status).toBe(404);
    expect(await response.json()).toEqual({
      error: {
        code: "route_not_found",
        message: "no route for GET /v1/nothing-here",
      },
    });
  });

  it("echoes the method back, so a reader can tell two similar paths apart", async () => {
    const response = await SELF.fetch(`${BASE}/v1/recoveries`, { method: "DELETE" });
    const body = (await response.json()) as { error: { message: string } };

    expect(response.status).toBe(404);
    expect(body.error.message).toBe("no route for DELETE /v1/recoveries");
  });
});

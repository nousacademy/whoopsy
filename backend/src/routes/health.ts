import { createRoute, OpenAPIHono, z } from "@hono/zod-openapi";
import type { Env } from "../env";
import { API_VERSION, SERVICE_NAME } from "../openapi";
import { validationHook } from "./errors";

/**
 * `GET /health` — liveness, and a report of what the isolate was handed.
 *
 * **It performs no query, and that is a decision with a failure behind it.** A liveness probe that
 * reads D1 turns a database blip into a restart loop: the platform sees a failed probe, replaces the
 * isolate, and the replacement fails its first probe for the same reason the database is unwell. So
 * this reports that the Worker is *running and answering* — which is the only thing it can honestly
 * claim — and describes the bindings beside it for a human reading the response.
 *
 * The binding report is a **shape** check rather than a presence check, and the difference is what
 * the compiler cannot do. `Env` declares `DB: D1Database`, so at the type level presence is already
 * asserted and a `c.env.DB !== undefined` test would either be dead code or a type error. What the
 * type cannot assert is that the *runtime* binding is the kind of thing it claims to be — a
 * `wrangler.toml` block pointed at the wrong resource, or a binding left undeclared, both typecheck
 * and both fail at the first `prepare`. Testing for the method that will actually be called is the
 * check that catches those, and it needs no cast.
 *
 * A `false` in `bindings` does **not** make this endpoint fail, and that is the same argument as
 * above one turn further: a probe that goes unhealthy over a configuration mistake is a probe that
 * restarts a Worker which is running perfectly well. The response is a diagnostic, and the diagnosis
 * is the reader's to make.
 *
 * **The version it reports is the implementation's, and publishing it unauthenticated is a deliberate
 * trade.** This path answers without a credential, so `version` fingerprints the running build to
 * anyone who can reach the Worker — which is the point of it: *"which version is deployed?"* becomes
 * one `curl` instead of a guess from the contract. It is **not** the number in the URL and the two are
 * allowed to differ; `API_VERSION` in `../openapi` carries that reasoning, and `docs/BACKEND.md`
 * § Versioning carries the policy. **Nothing about the gate is reported here** — `bindings` is
 * booleans, and no secret, token or credential is ever echoed.
 */

const healthRoute = createRoute({
  method: "get",
  path: "/health",
  summary: "Liveness",
  description:
    "Answers while the Worker is running. Reads nothing — a liveness probe that queried D1 would turn a database blip into a restart loop — and reports which bindings the isolate was handed.",
  responses: {
    200: {
      description: "The Worker is up, with a report of its bindings.",
      content: {
        "application/json": {
          schema: z
            .object({
              status: z.literal("ok").openapi({
                description: "Always `ok`. This endpoint answers only when the Worker is running, so there is no other value it could honestly return.",
              }),
              service: z.string().openapi({
                description: "The Worker's name, as `wrangler.toml` declares it.",
                example: "whoopsy-sync",
              }),
              // The example is the constant itself, where `service`'s is a literal that has to agree
              // with `SERVICE_NAME` by hand — `wrangler.toml` is not importable, so that one cannot be
              // derived. This one can, and a published example that is always the served value is one
              // fewer string to keep in step.
              version: z.string().openapi({
                description:
                  "The implementation version this Worker is running, read from `API_VERSION`. It is the API's own semver and is deliberately decoupled from the address in the URL — this deployment answers on `/v1` while reporting `0.1.0`, because the prefix moves only when the wire needs a new address. See `docs/BACKEND.md` § Versioning.",
                example: API_VERSION,
              }),
              bindings: z
                .object({
                  db: z.boolean().openapi({
                    description: "Whether `DB` is a usable D1 binding. A shape test, not a connection test — no query is issued.",
                  }),
                  exports: z.boolean().openapi({
                    description: "Whether `EXPORTS` is a usable R2 binding. Declared by the scaffold and unwritten by this slice.",
                  }),
                })
                .openapi({ description: "Which bindings this isolate was handed, by shape." }),
            })
            .openapi("Health", {
              description: "The Worker's liveness and its binding report.",
            }),
        },
      },
    },
  },
});

export const healthRoutes = new OpenAPIHono<{ Bindings: Env }>({
  defaultHook: validationHook,
}).openapi(healthRoute, (c) =>
  c.json(
    {
      status: "ok" as const,
      service: SERVICE_NAME,
      version: API_VERSION,
      bindings: {
        // `?.` on a non-optional property compiles: TypeScript permits it and the runtime lookup is
        // what is being tested, so the optional chaining is the check rather than a redundancy.
        db: typeof c.env.DB?.prepare === "function",
        exports: typeof c.env.EXPORTS?.get === "function",
      },
    },
    200,
  ),
);

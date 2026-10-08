import { OpenAPIHono } from "@hono/zod-openapi";
import type { Env } from "./env";
import { openApiConfig, serialiseOpenApiDocument } from "./openapi";
import { errorHandler, statusFor } from "./routes/errors";
import { routes } from "./routes";
import { apiError } from "./utils/errors";
import { MIN_TOKEN_LENGTH, bearerToken, tokensMatch } from "./utils/tokens";

/**
 * The paths that answer without a credential.
 *
 * **An exemption list rather than a `/v1/*` prefix on the gate, and the asymmetry is the reason.** A
 * prefix rule fails **open**: a resource mounted tomorrow at some other path is silently public, no
 * test reports it, and the only way to notice is to read this file and think about what is missing
 * from it. An exemption list fails **closed**: a new route is protected by default, and one that was
 * meant to be public answers 401 loudly on its first request. This is the same rule `routes/index.ts`
 * states for the validation hook and `onError` states below — the default must be the safe one,
 * because the failure of a default is what nobody reviews.
 *
 * Both entries are infrastructure rather than API. `GET /openapi.json` is the served contract, and the
 * iOS client reads the committed file rather than this endpoint. `GET /health` is a liveness probe —
 * and it deliberately reports nothing about whether the gate is armed, because a probe that does is a
 * probe that tells a stranger which Workers are worth attacking.
 *
 * Matched with `===` against `c.req.path` rather than by prefix, so `/health` does not also exempt
 * `/health-secret` or `/health/anything`.
 */
const OPEN_PATHS: readonly string[] = ["/health", "/openapi.json"];

/**
 * The Worker's one app definition, built by a function rather than exported as a value.
 *
 * **`src/index.ts` is not the app; it is the entry point.** Cloudflare's runtime asks a module for a
 * `fetch` handler, and the OpenAPI generator needs the app object itself — so the app is built here,
 * the entry point delegates to it, and the export script imports the same function. That is what
 * makes the served document and the checked-in one come from one definition instead of two that agree
 * today: there is exactly one `OpenAPIHono` in this Worker, and both readings of the contract are
 * taken from it.
 *
 * A factory rather than a module-level const for the ordinary reason — a test can build its own app
 * without sharing state with another — and, more concretely, because the document cache below is
 * per-instance and a shared instance would carry it across a test file's cases.
 *
 * **Its return type is inferred on purpose.** Annotating it `OpenAPIHono<{ Bindings: Env }>` looks
 * tidier and does not compile: mounting `routes` merges each mounted route's request and response
 * types into the app's schema parameter, so the real type is that generic carrying a large
 * intersection — and a wider annotation has to be assignable in both directions where the schema
 * appears. Callers need only `fetch` and `getOpenAPI31Document`, both of which inference provides.
 */
export function createApp() {
  const app = new OpenAPIHono<{ Bindings: Env }>({});

  /**
   * The gate. **It must be registered before `.route()` below, and that is load-bearing rather than
   * tidy.**
   *
   * Hono seeds a matched route's handler array with the wildcard middleware registered *earlier* than
   * it and runs that array in order. Every handler in this Worker returns a `Response` without calling
   * `next`, so a gate registered *after* the mount would sit behind them in the array and never run —
   * an open API behind a green suite, with nothing anywhere reporting it. Splitting the chained
   * `new OpenAPIHono({}).route("/", routes)` into two statements is what makes the position writable
   * at all.
   *
   * The second ordering trap, for whoever adds a second `use`: Hono sorts wildcard patterns by length
   * **descending**, so a later-registered `use("/v1/*")` runs *before* an earlier-registered
   * `use("*")` regardless of the order they appear in this file. Length, not registration order,
   * decides.
   *
   * `*` rather than `/v1/*` — see `OPEN_PATHS` above.
   *
   * **The two refusal arms answer differently on purpose.**
   *
   * An *unarmed* Worker — `SYNC_API_TOKEN` absent, empty, or shorter than `MIN_TOKEN_LENGTH` — throws,
   * which the funnel below turns into a `500 internal_error`. It is not the caller's fault and not a
   * state this Worker knows how to serve under. Answering `401` here would be a lie to a human holding
   * a curl: it says "your credential is wrong" when the truth is "the server has none", and it
   * collapses the distinction the rest of this repo keeps between a caller's mistake and a Worker bug.
   * The detail goes to the log and nothing about it is disclosed by the difference.
   *
   * A *presented* credential that is missing, malformed or simply wrong is a `401` in the shared
   * envelope — a refusal made on purpose, about a request. **Absent and wrong get the same message**,
   * because the difference is an oracle this API has no reason to publish.
   */
  app.use("*", async (c, next) => {
    if (OPEN_PATHS.includes(c.req.path)) return next();

    const configured = c.env.SYNC_API_TOKEN;

    if (configured === undefined || configured.length < MIN_TOKEN_LENGTH) {
      throw new Error(
        `SYNC_API_TOKEN is not configured (absent, or shorter than ${MIN_TOKEN_LENGTH} characters). ` +
          "Set it with `wrangler secret put SYNC_API_TOKEN` for a deployment, or in backend/.dev.vars " +
          "for `wrangler dev` — see README.md § The backend.",
      );
    }

    const presented = bearerToken(c.req.header("authorization"));

    if (presented === null || !(await tokensMatch(presented, configured))) {
      return c.json(
        apiError(
          "unauthorized",
          "the Authorization: Bearer credential is missing, or it does not match the one this deployment accepts",
        ),
        statusFor("unauthorized"),
      );
    }

    return next();
  });

  app.route("/", routes);

  /**
   * The served copy of the contract.
   *
   * **A plain `get` and not an `openapi()` route, deliberately.** An `openapi()` route registers its
   * path in the registry, so `GET /openapi.json` would appear inside the document it serves — an
   * endpoint listed in a contract whose own body does not describe it, describing itself. It is also
   * not an API surface a client calls: the iOS app reads the committed file, and this exists so a
   * human (or a shell gate) can see what the deployed Worker is actually answering without running
   * the generator against a checkout.
   *
   * **Memoised per origin, and the origin is the `Host` the request arrived on.** The document is
   * generated from the registry, which is fixed at module load, and from `openApiConfig(origin)` —
   * and the origin is the one part of it a request decides. Without the cache every fetch of this
   * path would re-walk the whole registry to produce bytes identical to the last ones. The cache holds
   * the *serialised string*, so the expensive half is what is cached and the `Response` is cheap.
   *
   * **One entry rather than a `Map`, and that is a limit an attacker does not get to set.** In
   * practice an isolate answers on one hostname and the entry is written once, so a keyed map would
   * only ever hold the same pair — while a map keyed on a caller-controlled header grows by one
   * serialised document per `Host` a stranger sends.
   *
   * **`c.req.url` is where the origin comes from, and that is what makes a deployment describe
   * itself with nothing configured.** A document fetched from `https://<host>/openapi.json` names
   * `https://<host>`, and one fetched from `wrangler dev` names `http://localhost:8787` rather than
   * the template. The committed `shared/openapi.json` cannot do this — a script has no request to
   * read an origin from — so the two readings differ in this one field, which `openapi.ts`'s module
   * comment argues and README § The backend shows how to compare them.
   *
   * Lazy rather than computed at construction: an isolate that never serves this path should not pay
   * for it on a request that is going to `GET /v1/recoveries/…`.
   */
  let served: { origin: string; body: string } | null = null;

  app.get("/openapi.json", (c) => {
    const origin = new URL(c.req.url).origin;

    if (served?.origin !== origin) {
      served = {
        origin,
        body: serialiseOpenApiDocument(app.getOpenAPI31Document(openApiConfig(origin))),
      };
    }

    return c.body(served.body, 200, {
      "content-type": "application/json; charset=utf-8",
    });
  });

  /**
   * An unmatched path, in the shared envelope.
   *
   * Hono's default is a bare `404 Not Found` — text, no body, and the one response a client cannot
   * tell apart from a reverse proxy's. The published contract says every non-2xx response this API
   * produces has the `{ error: { code, message } }` shape, and that promise has to hold for the paths
   * that *are not* routes as much as for the ones that are; a client switching on `code` would
   * otherwise fall into its default arm on the most common mistake there is, a typo in a URL.
   *
   * The message names the method and path. Both are the caller's own input echoed back, so nothing is
   * disclosed, and a developer reading it does not have to guess which of two similar paths they hit.
   */
  app.notFound((c) =>
    c.json(apiError("route_not_found", `no route for ${c.req.method} ${c.req.path}`), 404),
  );

  /**
   * The single place a thrown error becomes a response — `routes/errors.ts` holds what it decides.
   *
   * It goes on this app and not on the mounted routers: Hono looks for `onError` on the app whose
   * handler threw, and a handler registered on a sub-app only covers that sub-app's own middleware
   * chain. One installation here covers every route in the Worker, including one mounted tomorrow.
   */
  app.onError(errorHandler);

  return app;
}

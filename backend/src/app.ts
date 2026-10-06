import { OpenAPIHono } from "@hono/zod-openapi";
import type { Env } from "./env";
import { openApiConfig, serialiseOpenApiDocument } from "./openapi";
import { errorHandler } from "./routes/errors";
import { routes } from "./routes";
import { apiError } from "./utils/errors";

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
  const app = new OpenAPIHono<{ Bindings: Env }>({}).route("/", routes);

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
   * **Memoised, because the document cannot change within an isolate.** It is generated from the
   * registry, which is fixed at module load, and from `openApiConfig`, which is a constant — the
   * config is deliberately not the `(c) => config` form, so there is nothing request-dependent to
   * generate. Without the cache every request to this path re-walks the whole registry and
   * re-serialises the document to produce bytes identical to the last ones. The cache holds the
   * *serialised string*, so the expensive half is what is cached and the `Response` is cheap.
   *
   * Lazy rather than computed at construction: an isolate that never serves this path should not pay
   * for it on a request that is going to `GET /v1/recoveries/…`.
   */
  let servedDocument: string | null = null;

  app.get("/openapi.json", (c) => {
    servedDocument ??= serialiseOpenApiDocument(app.getOpenAPI31Document(openApiConfig));

    return c.body(servedDocument, 200, {
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

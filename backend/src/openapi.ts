import type { OpenAPIHono } from "@hono/zod-openapi";
import type { Env } from "./env";

/**
 * The OpenAPI document's configuration, and the one way it is turned into bytes.
 *
 * This file exists because the contract has **one source and two readings**: the Worker serves the
 * document live at `GET /openapi.json`, and `scripts/export-openapi.ts` writes the same document to
 * `shared/openapi.json` for the iOS client to read. Both call `getOpenAPI31Document(openApiConfig)`
 * with the config below and both serialise it with `serialiseOpenApiDocument`, so the two readings
 * cannot differ — not in the paths, and not in the pretty-printing either.
 *
 * **The prose lives here and nowhere else.** The document's `info` block is the one part of the
 * contract that is not generated from the routes, and a copy of it in the script would be a second
 * source for the same sentences. `shared/openapi.json`'s checked-in description and this one are the
 * same string because the file is written from this config, not because someone kept them in step.
 *
 * **Nothing here may import from `routes/`.** `routes/health.ts` reads `SERVICE_NAME` from this
 * module, and the route files are what the app under `app.ts` is built from — so an import in this
 * direction (openapi.ts → app.ts → routes/index.ts → openapi.ts) would be a cycle. This module stays
 * a leaf: it knows the document's identity and how to write it down, and it knows nothing about what
 * is in it.
 */

/**
 * The Worker's name, as `wrangler.toml` declares it.
 *
 * Exported rather than typed into each place that says it, because two of them are reachable from a
 * response body: `GET /health` reports it, and the document's title is built from the same product
 * name. A rename that reached `wrangler.toml` and missed one of them would be a Worker answering to
 * one name and identifying as another.
 */
export const SERVICE_NAME = "whoopsy-sync";

/**
 * The config type, taken from the generator's own signature rather than restated.
 *
 * `OpenAPIObjectConfig` is declared in `@hono/zod-openapi`'s type definitions but **is not among its
 * exports** — the export list carries `OpenAPIObjectConfigure` instead, which is a union of a config
 * object and a `(c) => config` function and would have to be narrowed back to the half this needs.
 * Deriving the parameter type from the method that consumes it is the honest alternative: the
 * annotation cannot drift from the generator, because it *is* the generator's.
 *
 * The annotation earns its line. Without it the object below would be inferred, and inference has no
 * excess-property check — a misspelled `server:` key would be a silently ignored field on a document
 * that still generates, still validates and simply never publishes the servers block. Annotated, it
 * is a compile error here.
 */
type OpenApiDocumentConfig = Parameters<
  OpenAPIHono<{ Bindings: Env }>["getOpenAPI31Document"]
>[0];

/**
 * The document's identity: what it is, and where the deployed Worker would answer.
 *
 * `info` is carried through generation untouched — `OpenApiGeneratorV31.generateDocument` merges its
 * own `{ components, paths }` over this config rather than replacing it — so everything written here
 * reaches both the served document and the checked-in file.
 *
 * The description's first two sentences are the stub's own and are quoted rather than rewritten: they
 * state the property that makes the file worth committing at all, which is that it is generated from
 * the route definitions and therefore cannot disagree with the Worker. Only the trailing clause about
 * `paths` being empty changed, because this pass is the one that made it false.
 *
 * `servers` is no longer a placeholder: the first `wrangler deploy` has run, and the URL below is the
 * hostname it printed. The account subdomain is a per-account fact, so it could not have been guessed
 * — which is why this line stayed a placeholder through the whole of the provisioning step, when
 * `wrangler.toml`'s `database_id` already held a real id. **Provisioning is not deploying**, and this
 * is the field where the difference was visible.
 *
 * **It is one deployment's hostname, and a fork's is different.** Nothing in the app reads this value
 * — the client is handed its own base URL through `Info.plist`, and the Worker never reads its own
 * `servers` block either — so a fork that deploys under another account has a stale string here and
 * nothing breaks. It is documentation, and it is regenerated with everything else.
 */
export const openApiConfig: OpenApiDocumentConfig = {
  openapi: "3.1.0",
  info: {
    title: "Whoopsy Sync API",
    version: "0.0.0",
    description:
      "The API contract shared between the Worker and the iOS client. It is generated from the Hono route definitions in backend/src/routes/ rather than written by hand, so this file and the Worker cannot disagree. Regenerate it with `npm --prefix backend run openapi` after changing those routes. This document is also served live by the Worker at `GET /openapi.json`, from the same configuration.",
  },
  servers: [
    {
      url: "https://whoopsy-sync.your-account-subdomain.workers.dev",
      description:
        "The deployed Worker. Every `/v1` path requires `Authorization: Bearer <SYNC_API_TOKEN>`; `GET /health` and `GET /openapi.json` are the two that answer without it.",
    },
  ],
};

/**
 * The one way this document becomes text.
 *
 * **There is deliberately no second one.** `app.doc31()` exists and would serve the document in a
 * line, but it serialises compactly — one long line — while `shared/openapi.json` is a reviewed,
 * committed, diffed file that has to be readable and has to produce a small diff when one route
 * changes. A route mounted through `doc31` would therefore be a second serialiser, and the served
 * document and the checked-in one would stop being the same bytes the moment anyone used it. So the
 * server handler and the export script both call this.
 *
 * The trailing newline is not cosmetic: it is what stops `git diff` from reporting `\ No newline at
 * end of file` on every regeneration, and what lets the shell gate (`curl … | diff - shared/openapi.json`)
 * compare two files that both end the way a text file should.
 */
export function serialiseOpenApiDocument(document: unknown): string {
  return `${JSON.stringify(document, null, 2)}\n`;
}

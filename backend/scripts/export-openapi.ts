import { writeFileSync } from "node:fs";
// `URL` is imported rather than used as the ambient global, and that is load-bearing: this project
// loads `@cloudflare/workers-types` (it imports `src/app`, whose `Env` names `D1Database`), and that
// package declares a global `URL` which is *not* the one `fileURLToPath` accepts. The named import
// from `node:url` is the same class at runtime and the right one at compile time.
import { fileURLToPath, URL } from "node:url";
import { createApp } from "../src/app";
import { RELATIVE_ORIGIN, openApiConfig, serialiseOpenApiDocument } from "../src/openapi";

/**
 * Writes the API contract to `shared/openapi.json`.
 *
 * This is the **second reading of one source**. The Worker serves the same document live at
 * `GET /openapi.json`; this script produces the committed copy the iOS client reads. Both call
 * `createApp()` and `getOpenAPI31Document(openApiConfig)` and both serialise with
 * `serialiseOpenApiDocument`, so the two cannot say different things — and the shell gate
 * (`curl …/openapi.json | diff - shared/openapi.json`) is what checks that claim rather than
 * trusting it.
 *
 * **It writes the file unconditionally, and that is what makes the gate work.** A run that changed
 * nothing rewrites identical bytes, so `git diff --exit-code -- shared/openapi.json` afterwards
 * answers one question — *is the committed contract the one the code generates* — rather than two.
 * A script that skipped the write on "no change" would leave a stale file looking current.
 *
 * **Paths are resolved from this file and never from the working directory.** `npm --prefix backend
 * run openapi` and a bare `tsx scripts/export-openapi.ts` from inside `backend/` both reach this
 * file, and `../shared/` means something different under each. `import.meta.url` is the anchor that
 * makes the two agree — the same reason `vitest.config.ts` resolves the migrations directory this
 * way, and the reason the generated file lands in the repo rather than in whichever directory
 * happened to be current.
 *
 * **It runs under `tsx` and not under `node`.** Node 26 strips types by default, but its ESM
 * resolver still demands an explicit extension on every relative import, and this Worker's sources
 * are written extensionlessly under `moduleResolution: "bundler"` — so `node` fails on the first
 * `import` above. `tsx` resolves bundler-style, which is the only reason it is a devDependency.
 *
 * **The committed contract carries a relative origin and the served one an absolute, and that is the
 * asymmetry between the two readings.** `servers[0].url` is the only field in the document that is a
 * fact about a *deployment* rather than about the API — and this file is **committed**, so it must not
 * name one. It writes `RELATIVE_ORIGIN`, the OpenAPI relative form meaning *the origin this document
 * was fetched from*: true of every deployment that serves it, and a single operator's subdomain in a
 * repository everyone reads if it were a hostname instead. The Worker's own reading takes the
 * absolute form, `app.ts` naming the origin each request arrived on, which is why the shell gate
 * drops exactly that line. **There is nothing to configure here**, deliberately: an env var that let
 * a clone write its own hostname into this file would reintroduce the one thing the relative origin
 * exists to keep out of it.
 */

const target = fileURLToPath(new URL("../../shared/openapi.json", import.meta.url));
const relativeTarget = "../shared/openapi.json";

try {
  const document = createApp().getOpenAPI31Document(openApiConfig(RELATIVE_ORIGIN));

  writeFileSync(target, serialiseOpenApiDocument(document), "utf8");

  console.log(`openapi: wrote ${relativeTarget}`);
} catch (error) {
  // Named before it is rethrown: an uncaught exception from here prints a stack whose top frame is
  // inside the generator or the filesystem, and "which output file was it trying to write" is the
  // first thing a reader wants and the one thing that stack does not say.
  console.error(`openapi: could not write ${relativeTarget}`);
  throw error;
}

import { createApp } from "./app";
import type { Env } from "./env";

/**
 * The Worker's entry point, and nothing more.
 *
 * Cloudflare's runtime asks a module for a `fetch` handler, so this file's whole job is to build the
 * app once and hand requests to it. **The app itself is `src/app.ts`**, and that split is not tidiness:
 * the OpenAPI document is generated *from* the app object, so the generator needs one that can be
 * imported without also importing the Worker's default export. Building it here instead would put a
 * `export default` between the generator and its input.
 *
 * **Built at module scope, so it is built once per isolate** rather than once per request. Nothing in
 * the app holds request state — `env` arrives as an argument to `fetch` and is threaded to the
 * repository per call — so one instance serves every request the isolate handles, and the document
 * cache in `createApp` survives between them.
 *
 * The `satisfies ExportedHandler<Env>` guard is kept: it is what makes a mistyped export name or a
 * `fetch` with the wrong arity a compile error rather than a Worker the platform silently declines to
 * route anything to.
 *
 * The layer split the router mounts into is `routes/` → `services/` → `domain/`, with `repositories/`
 * hanging off the last as the adapter behind the port: a controller parses a request, calls a service
 * and shapes a response; a service holds policy and depends on a shape and a port rather than on a
 * table; `domain/` is what a resource *is* beside the port that reads it, and imports nothing at all;
 * and `repositories/` is the only place that knows a table or a bucket exists. The wire contract sits
 * outside that chain in `dto/`, which depends on `domain/` and on nothing else — so "where does Zod
 * live" has exactly one answer, as "where does SQL live" has one.
 */
const app = createApp();

export default {
  fetch: (request, env, ctx) => app.fetch(request, env, ctx),
} satisfies ExportedHandler<Env>;

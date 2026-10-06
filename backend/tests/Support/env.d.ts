import type { D1Migration } from "cloudflare:test";
import type { Env } from "../../src/env";

/**
 * The Worker's bindings, plus the one test-only binding, as the test runtime sees them.
 *
 * `ProvidedEnv` is declared empty inside the pool's own `cloudflare:test` module and exists to be
 * extended exactly like this — it is the documented way to tell the compiler what `env` holds,
 * because that object is built from `wrangler.toml` at runtime and there is nothing for TypeScript
 * to infer it from.
 *
 * `extends Env` rather than a restated list: the specs read `env.DB`, and typing it by hand would
 * be a second declaration of the Worker's bindings that could disagree with `src/env.ts` — which is
 * the one `src/index.ts` is compiled against. It also means a spec that reaches for a binding the
 * Worker does not declare is a compile error rather than `undefined` at the first `prepare`.
 *
 * `TEST_MIGRATIONS` is the exception and is spelled out, because it is the one binding that exists
 * only here: `vitest.config.ts` supplies it from `readD1Migrations`, `tests/Support/apply-migrations.ts`
 * consumes it, and no production code may see it.
 *
 * **This file sits in `Support/` because nothing in `src/` is its counterpart.** It declares the
 * shape of a runtime that exists only while the suite runs, which is the same reason
 * `apply-migrations.ts` is beside it — see `vitest.config.ts` for the tree rule.
 */
declare module "cloudflare:test" {
  interface ProvidedEnv extends Env {
    readonly TEST_MIGRATIONS: D1Migration[];
  }
}

import { applyD1Migrations, env } from "cloudflare:test";

/**
 * Applies the Worker's migrations to the test database, once per test file.
 *
 * This is the runtime half of a two-part arrangement, and the split is forced rather than chosen:
 * `vitest.config.ts` cannot apply anything (it is a Node module and there is no `D1Database` in
 * Node), and this file cannot read anything (it runs inside `workerd`, which has no filesystem).
 * So the config reads the directory with `readD1Migrations` and passes the statements in as the
 * `TEST_MIGRATIONS` binding; this applies them.
 *
 * **`applyD1Migrations` and not `wrangler d1 migrations apply --local`.** The CLI writes to
 * `.wrangler/state`, which is the *dev* database — a shared file a `wrangler dev` session is also
 * using — while this applies to the pool's own per-test storage. Running the CLI before a test run
 * would leave the suite passing against rows it did not create.
 *
 * A top-level `await` and not a `beforeAll`: setup files are awaited before the file's first test,
 * and there is nothing here to scope to a suite — every spec below assumes the schema exists,
 * including the ones that only read. Each file gets this fresh because `isolatedStorage` is on.
 *
 * **It sits in `Support/` because it has no counterpart in `src/`** — it is the harness rather than
 * a test of anything, which is the one thing in this tree that deliberately does not mirror. See
 * `vitest.config.ts` for the rule.
 */
await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);

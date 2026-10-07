import {
  defineWorkersConfig,
  readD1Migrations,
} from "@cloudflare/vitest-pool-workers/config";
// `URL` is imported rather than used as the ambient global, and that is load-bearing: this file
// loads `@cloudflare/workers-types` (it imports `src/`, whose `Env` names `D1Database`), and that
// package declares a global `URL` which is *not* the one `fileURLToPath` accepts. The named import
// from `node:url` is the same class at runtime and the right one at compile time.
import { fileURLToPath, URL } from "node:url";
import { TEST_API_TOKEN } from "./tests/Support/auth";

/**
 * The test pool: the real Worker, the real SQL, and no deploy.
 *
 * `@cloudflare/vitest-pool-workers` runs each test file inside `workerd` with `SELF` bound to the
 * Worker's own default export, so a spec drives `app.fetch` through the same router, the same
 * validation hook and the same `onError` a request from the internet would. The alternative —
 * importing `createApp()` and calling it directly — would still be a step short of real: it skips
 * the runtime's binding wiring, which is the half `health.ts` exists to report on.
 *
 * **The migrations are read here and applied there.** `readD1Migrations` runs on the *Node* side
 * (this file is a Node module, and this is the only place the migrations directory is read from
 * disk), splits each file into its statements, and hands the array to the Worker as a plain
 * `TEST_MIGRATIONS` binding. `tests/Support/apply-migrations.ts` then calls
 * `applyD1Migrations(env.DB, …)` inside the runtime, where a filesystem does not exist. That split is
 * why the binding is an array of strings rather than a directory path, and it is the pool's own
 * documented shape.
 *
 * **`tests/` mirrors `src/`, and that is the rule that answers "where does this spec go?".** A spec
 * is named `<SourceFile>.spec.ts` and sits at its source file's own path with `src/` dropped — so
 * `src/routes/recoveries.ts` is tested by `tests/routes/recoveries.spec.ts` and `src/utils/identity.ts`
 * by `tests/utils/identity.spec.ts`, and a new route, service or repository is findable without
 * searching. The app's Swift runner holds the same rule for `ios/Sources/Whoopsy/`, and it is
 * stated there for the reason it is stated here: a tree that mirrors makes the *absence* of a test
 * legible, which is the only thing a directory listing can tell you. **`Support/` deliberately does
 * not mirror**, because the harness has no counterpart in `src/` — `apply-migrations.ts` is setup
 * rather than a test of anything, and `env.d.ts` declares a runtime that exists only while the suite
 * runs. `tsconfig.json` stays at the root beside them for the same kind of reason: it is the test
 * project's own configuration, not a file describing any source.
 *
 * **`dto/` and `domain/` deliberately have no specs of their own, and that is a second exception
 * rather than a hole in the tree.** They are the wire contract and the entities-and-ports, and both
 * are exercised through the route specs that consume them rather than through a spec apiece — a
 * `domain/workout.ts` constant arrives as `tests/routes/workouts.spec.ts`'s `ZONE_COUNT`, a
 * `dto/sleeps.ts` bound as `tests/routes/sleeps.spec.ts`'s `MAX_SLEEP_STAGES_LENGTH` — so what those
 * directories export is asserted on the path a request actually takes, and a spec at their own path
 * would be a spec asserting a type. The rule above is therefore "the tree mirrors the code that has
 * behaviour of its own", and the two directories without specs are the two where it does not.
 *
 * The placement is enforced by nothing, which is why it is written down: vitest discovers specs by
 * glob, so a spec dropped in the wrong directory still runs and still passes. What it loses is the
 * one thing the tree is for.
 *
 * **The path resolves from this file, never from the working directory.** `vitest run` from
 * `backend/` and `npm --prefix backend test` from the repo root both land here, and a relative
 * `"migrations"` would mean two different directories under the two — the same reason
 * `scripts/export-openapi.ts` anchors on `import.meta.url`. (`__dirname` is not available: the
 * package is `"type": "module"`.)
 *
 * `isolatedStorage` is left at its default of `true`, so each *test* runs against its own stacked
 * copy of the database and the setup file's migrations are re-applied per test file. That is
 * correct before it is fast — a spec cannot see another's rows — and the lever if it ever becomes
 * slow is `singleWorker`, not deleting the setup file.
 */
const migrationsDirectory = fileURLToPath(new URL("./migrations", import.meta.url));

const migrations = await readD1Migrations(migrationsDirectory);

export default defineWorkersConfig({
  test: {
    setupFiles: ["./tests/Support/apply-migrations.ts"],
    poolOptions: {
      workers: {
        // Reading `wrangler.toml` rather than restating its bindings here is what keeps the test
        // database and the deployed one from being two configurations: `DB` and `EXPORTS` arrive
        // with the names, and the types, the Worker is compiled against.
        wrangler: { configPath: "./wrangler.toml" },
        miniflare: {
          bindings: {
            TEST_MIGRATIONS: migrations,
            // The one binding that is deliberately **not** in `wrangler.toml`, and the exception is
            // the rule it is an exception to. Every other binding is read from that file above
            // precisely so the test runtime and the deployed one cannot be two configurations; a
            // *secret* is the one thing that must not be there — `wrangler.toml` is committed, and
            // `backend/.dev.vars` (gitignored) is where a real one lives.
            //
            // So the test value comes from `tests/Support/auth.ts` instead, imported by *this* file
            // and bound here, which is what keeps the config and the specs from disagreeing about
            // it: `authHeaders()` reads the same constant, so a spec cannot send a token the runtime
            // was not told to accept.
            SYNC_API_TOKEN: TEST_API_TOKEN,
          },
        },
      },
    },
  },
});

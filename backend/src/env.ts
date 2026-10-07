/**
 * The Worker's bindings, named once.
 *
 * Every layer needs these — a route reads `c.env`, a service is handed them, a repository is
 * constructed with one — so the interface lives here rather than on the entry point, which would
 * make `routes/` import from `index.ts` and the dependency run the wrong way.
 *
 * The names are `wrangler.toml`'s `binding` values and must match it exactly; a mismatch is a
 * runtime `undefined`, not a compile error.
 */
export interface Env {
  /** D1 — accounts, devices, and the per-day rows the app already keeps locally. */
  readonly DB: D1Database;
  /** R2 — bulk payloads, keyed by device and day. */
  readonly EXPORTS: R2Bucket;
  /**
   * The shared secret every client sends as `Authorization: Bearer …`.
   *
   * **Optional, and that is the honest type rather than a convenience.** `DB` and `EXPORTS` are
   * declared in `wrangler.toml` and therefore always bound; a *secret* is never in that file — it is
   * set with `wrangler secret put` and read from `backend/.dev.vars` under `wrangler dev`, so on a
   * checkout that has done neither the binding is genuinely absent. Typing it `string` would be a
   * claim the Worker cannot make, and it would not compile either: the gate tests it against
   * `undefined`, which is a `TS2367` against a non-optional `string`.
   *
   * Absent or too short is not a request-level failure — see `createApp`, which refuses to serve at
   * all rather than answering 401 to a caller whose credential was never the problem.
   */
  readonly SYNC_API_TOKEN?: string;
}

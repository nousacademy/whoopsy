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
}

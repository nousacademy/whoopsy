---
name: api-versioning
description: Use whenever the Worker's API version or its `/v1` address changes, and whenever a change to a route, a DTO, a schema or a bound might force one — renaming a property or an endpoint, making an optional field required, changing a field's format or type, or moving a `maxLength`. It keeps the coupled sites in step - `API_VERSION` and `API_PREFIX` in `backend/src/openapi.ts`, the `version` in `backend/package.json`, the eight `${API_PREFIX}` mounts in `backend/src/routes/index.ts`, the `version` field `backend/src/routes/health.ts` reports, the generated `shared/openapi.json`, the two health-body assertions in `backend/tests/app.spec.ts` and `backend/tests/routes/health.spec.ts`, the seven path strings in `ios/Sources/Whoopsy/Domain/Entities/SyncedResource.swift`, their mirror in `SyncedResourceTests.swift`, the path enumeration in `README.md`, `docs/BACKEND.md` § Versioning, and the skills list in `CLAUDE.md`. It also carries the bump rule and the deprecation procedure.
---

# API Versioning

The Worker has **two numbers**, and they are not the same number. `API_VERSION` is the
**implementation** version — `backend/package.json`, the contract's `info.version`, `GET /health`.
`API_PREFIX` is the **contract** — the `/v1` segment in every URL the app calls, and it moves only when
the wire needs a new address. This deployment answers on `/v1` while reporting `0.1.0`, and **the `1` in
the URL is not that version's major**: `/v1` is a frozen address a sideloaded binary already holds.

The policy is written out in `docs/BACKEND.md` § Versioning. This skill is the procedure that keeps the
sites in step, and it exists because **almost nothing here is caught by the compiler**: `shared/openapi.json`
is generated rather than checked against the code, the client's seven paths are string literals in a
different language, and the failure mode of a missed one is a silent sync failure rather than a build
error.

Apply this skill **in the same change** as the edit that triggered it, not as a follow-up.

## Sites this skill owns

| Site | What it carries |
| :--- | :--- |
| `backend/src/openapi.ts` | **The source.** `API_VERSION` and `API_PREFIX`, both declared once, plus the prose that argues the two axes |
| `backend/package.json` | `version` — the implementation version. `tests/openapi.spec.ts` fails if it is not `API_VERSION` |
| `backend/src/routes/index.ts` | the **eight** `${API_PREFIX}/…` mounts — the prefix is interpolated, never spelled |
| `backend/src/routes/health.ts` | `version: API_VERSION` in the body **and** in the `createRoute` response schema |
| `shared/openapi.json` | **generated** — regenerate it, never hand-edit it |
| `backend/tests/openapi.spec.ts` | the version block: manifest equality, every published path but `/health` prefixed, the `servers` prose |
| `backend/tests/routes/health.spec.ts`, `backend/tests/app.spec.ts` | **two files**, each pinning the health body with `toEqual` |
| `ios/Sources/Whoopsy/Domain/Entities/SyncedResource.swift` | the **seven** `/v1/…` strings the client calls |
| `ios/Tests/WhoopsyTestRunner/Domain/Entities/SyncedResourceTests.swift` | re-lists all seven, and pins the contract at **23 paths / 8 roots** |
| `README.md` | enumerates all eight resource paths in prose, in three places |
| `docs/BACKEND.md` § Versioning | the policy itself |
| `CLAUDE.md` | the skills list |

## Rules

1. **The implementation version moves on every release; the prefix moves almost never.** Do not derive one
   from the other in either direction, and do not "fix" `0.1.0` to read `1.0.0` because the URL says
   `/v1`. A rewrite that leaves the wire alone is a new implementation and not a new contract.
2. **A change forces a version when it forces a consumer to alter code, and that is the whole test.** Bump
   for: a renamed property or endpoint, an optional field made required, a field's format or type change,
   a bound such as `maxLength` moving in a way a conforming client could exceed. Do **not** bump for: a
   field added, a required field made optional, a loosened bound, a new route, a service or query
   rewritten behind an unchanged shape, a comment moved. **A change that leaves the wire's names, types,
   requiredness, formats and bounds alone is not a version event**, however large it is.
3. **Pre-1.0 means the minor moves.** Until `1.0.0` a wire change that would otherwise take a major bump
   takes a **minor** one, and where the old shape can go on being served at `/v1` the address does not
   move at all. `0.x` is an explicit non-promise of stability rather than an oversight — say so rather
   than implying the version is simply young.
4. **Never hand-edit `shared/openapi.json`.** It is an output. `npm --prefix backend run openapi` rewrites
   it, and `make backend-check`'s last step is a `git diff --exit-code` on it, so a hand-edit is either
   overwritten or a gate failure.
5. **The constant is declared without a type annotation, and that is load-bearing.** A `: string` on
   `API_PREFIX` widens the template-literal type of `` `${API_PREFIX}/recoveries` `` and changes the app's
   inferred schema type — and therefore the generated contract. Declare it exactly as `SERVICE_NAME` is.
6. **A prefix bump is a client change too, and nothing in the Swift suite can see it.** The client's seven
   paths are literals in `SyncedResource.path`; a missed one compiles, ships, and fails at the socket. Grep
   `ios/` by hand — rule 9's command — and run `make build test` afterwards.
7. **Deprecation is announced, served, watched, then removed — and the headers are not built yet.** A
   forcing change leaves the old shape answering for a span written down *before* the new one ships. **Do
   not add `Deprecation` or `Sunset` response headers until there is a real deprecation to carry them**:
   the branch would never be the one that runs, which is the defect
   `ios/Sources/Whoopsy/Data/Health/HealthStoreClientFactory.swift:5-9` records for its unbuilt
   `UnavailableHealthStoreClient`.
8. **`/health` is deliberately unprefixed, and the prefix assertion exempts it by name.** The probe is
   infrastructure rather than API, which is why the test filters `paths` for anything that is not `/health`
   and does not begin with the prefix rather than counting. `/openapi.json` never appears under `paths` at
   all, which is asserted separately.
9. **Prose is not a site, and one migration is frozen.** `grep` returns far more hits than there are
   places to edit, and the difference matters:

   ```bash
   grep -rn "/v1" backend/src backend/tests ios/Sources ios/Tests shared docs/BACKEND.md README.md
   ```

   - **Prose mentions are not sites.** Explanations under `backend/src/dto/**`, `backend/src/services/**`,
     `backend/src/app.ts`, `ios/Sources/Whoopsy/Data/Networking/**` and `wrangler.toml:15` /
     `.dev.vars.example:19` name `/v1` in a sentence. They compile and pass whatever the constant says, so
     they go stale quietly — worth sweeping when the address moves, and worth nothing when it does not.
   - **`backend/migrations/0002_create_workouts.sql:10` is frozen.** D1 records an applied migration's
     identifier and does not checksum the body, so editing a shipped file changes nothing on a deployed
     database and only makes the tree disagree with it. Its `/v1` comment is left alone however wrong it
     would look after a move.
   - **`README.md` is a site and not prose**, because it enumerates the eight resource paths as the route
     list a reader trusts.

## Procedure

1. **Decide which axis moved.** Every release moves the implementation version. Only a change that forces
   a consumer to alter code moves the contract version, per rule 2 — and only a change the old shape
   cannot be served alongside moves the address.
2. **Edit `backend/src/openapi.ts`** — the constant(s), and the prose beside them if the reasoning changed.
3. **Edit `backend/package.json`'s `version` in the same change.** The two are asserted equal, so splitting
   them across two commits leaves one of them failing.
4. **If the address moved**, the sites are: all eight mounts in `routes/index.ts`, the seven cases in
   `SyncedResource.swift`, `SyncedResourceTests.swift`'s re-listing, and `README.md`'s three enumerations.
   The frozen migration is not among them — rule 9.
5. **Regenerate the contract**: `npm --prefix backend run openapi`.
6. **Run the gate**: `make backend-check` from the repo root.
7. **Re-measure for the client by hand**, because nothing in the gate can see it — rule 9's command, and
   then `make build test` if the address moved.

## Verification

| Check | Command | Expected |
| :--- | :--- | :--- |
| the whole gate | `make backend-check` | three typecheck projects, all specs, and the contract regenerates to a clean diff |
| the contract diff is only what you meant | `git diff -- shared/openapi.json` | for a version-only release, `info.version` and `components.schemas.Health` — **nothing under `paths`** |
| the constants cannot drift | `npm --prefix backend test` | the version block in `openapi.spec.ts` passes: every path but `/health` prefixed, manifest equal to `API_VERSION` |
| the iOS mirror is untouched | `make build test` | `SyncedResourceTests` passes — **23 paths, 8 roots, 7 cases** |
| the deployment self-describes | `curl <host>/health` | carries `version`, and reports no credential |

**Do not hand-edit `shared/openapi.json`** — it is generated, and the gate's last step is
`git diff --exit-code` on it.

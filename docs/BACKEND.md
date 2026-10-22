# The backend Worker

The Cloudflare Worker in `backend/` — Hono in front of D1 + R2 — and the eight resources it
carries. This is the reference for the Worker's own conventions; `CLAUDE.md` keeps only the
one-line version, because most work in this repo is on the app, not on the Worker.

`shared/openapi.json` is the contract the two halves agree on, and it is an **output** rather
than a hand-written stub — regenerate it with `npm --prefix backend run openapi`. **Its
`servers[0].url` is the one field in it that is not derived from the routes, and it is a relative
one**: the committed contract carries `/`, the OpenAPI form meaning *the origin this document was
fetched from*, because this file is committed and a hostname in it would be one operator's subdomain
in a repository everyone reads. Nothing in the Worker reads that value, and nothing under `backend/`
configures it. `GET /openapi.json` is where a deployment names itself instead — it publishes the
origin each request arrived on, so a deployed Worker reports its own hostname and `wrangler dev`
reports `http://localhost:8787`. That one field is the whole of why the served document and the
committed one differ in exactly one line.

## Versioning

**There are two numbers here and they are not the same number.** `API_VERSION` is the
**implementation** version — what `backend/package.json` declares, what the contract publishes as
`info.version`, and what `GET /health` reports. `API_PREFIX` is the **contract** — the `/v1` segment in
every URL the app calls — and it moves only when the wire needs a new address. This deployment answers on
`/v1` while reporting `0.1.0`, and **the `1` in the URL is not that version's major**: `/v1` is a frozen
address a shipped client already holds, not a claim about how many times compatibility has broken. The two
axes are decoupled deliberately, and it is the guide's plainest rule: a rewrite that leaves the wire alone
is a new *implementation* and not a new *contract*, and a prefix bump is the expensive one — it invalidates
every path in the binary, including the seven in
`ios/Sources/Whoopsy/Domain/Entities/SyncedResource.swift`. **Pre-1.0 is an explicit non-promise rather
than an oversight**: until `1.0.0` a wire change that would otherwise take a major bump moves the version's
**minor** instead, and where the old shape can go on being served at `/v1` the address does not move at
all.

**Both constants are declared once, in `backend/src/openapi.ts`, and every other site is derived from
them.** `shared/openapi.json` is **generated** — `npm --prefix backend run openapi` rewrites it from the
route definitions, and the gate's last step is a `git diff --exit-code` on it — so it is never
hand-edited, and a version wrong in it is a version wrong in the source. The mount table interpolates the
prefix into all eight `.route()` calls rather than spelling `/v1` eight times; `info.version` reads
`API_VERSION`; and `servers[0].description` interpolates the prefix too, which is a `/v1` written in
prose, in a field no path-level assertion reads — exactly where a stale version segment would otherwise
survive a sweep. **The manifest is checked rather than trusted**: `tests/openapi.spec.ts` imports
`package.json` and fails if its `version` is not `API_VERSION`, and fails if any published path but
`/health` does not begin with the prefix. The constant is declared **without a type annotation**, which is
load-bearing rather than stylistic: a `: string` would widen the template-literal type of
`` `${API_PREFIX}/recoveries` `` and change the app's inferred schema type, and therefore the contract.

**The URL path is the one strategy, and that is a decision rather than an omission** — no query parameter,
no `Accept-Version` header, no per-consumer negotiation. It is the strategy the guide calls the most
popular and the one this API can actually keep consistent: the app is the only consumer, its addresses are
compiled into a binary that is sideloaded rather than updated by a store, and a header scheme would have
to ride on every one of the nineteen `CloudSync` methods while buying nothing a path does not already
give.

**A change forces a version when it forces a consumer to alter code, and that is the whole test.** It is a
bump when a property or an endpoint is renamed, when an optional field becomes required, when a field's
format or type changes, or when a bound such as `maxLength` moves in a way a conforming client could
exceed. It is **not** a bump when a field is added, when a required field becomes optional, when a bound
loosens, when a route is added, when a service or a query is rewritten behind an unchanged shape, or when
a comment moves. **A change that leaves the wire's names, types, requiredness, formats and bounds alone is
not a version event**, however large it is.

**Deprecation is announced, served, watched, and only then removed.** A change that does force a bump
leaves the old shape answering for a span written down before the new one ships: the docs say what is
going and when, both shapes are served, the old one's use is watched for as long as that takes, and it is
removed once nothing calls it. **The `Deprecation` and `Sunset` response headers are deliberately not
implemented yet** — the procedure is written and the machinery arrives with the first real deprecation,
because a header added now would be a branch whose selecting path never runs. That is the same judgement
`ios/Sources/Whoopsy/Data/Health/HealthStoreClientFactory.swift:5-9` records for its unbuilt
`UnavailableHealthStoreClient`: a second implementation of an answer nobody asks for is a defect rather
than insurance. **Nothing is deprecated today** — there is one shape of every route, and `/v1` is the only
prefix this Worker has ever served.

## The gate

**Every `/v1` request needs `Authorization: Bearer <SYNC_API_TOKEN>`, and the two paths that do not
are `GET /health` and `GET /openapi.json`.** The check is one middleware inside `createApp()`, in
`backend/src/app.ts`, and it is registered **before** `.route("/", routes)` — which is load-bearing
rather than tidy. Hono seeds a route's handler array with the wildcard middleware registered
*earlier* and runs that array in order, and every handler in this Worker returns a `Response`
without calling `next`; a gate registered after the mount would therefore sit behind them and never
run, which is an open API behind a green suite. The same file records the second half of that trap:
wildcard patterns are sorted by length descending, so a later `use("/v1/*")` would run *before* an
earlier `use("*")` whatever the registration order.

**It is a global `use("*")` with an exemption list, not a `/v1/*` prefix, and the asymmetry decides
it.** A prefix rule fails **open** — a resource mounted tomorrow at some other path is silently
public and no test reports it — while an exemption list fails **closed**: a new route is protected
by default, and a mistakenly-public one `401`s loudly on its first request. That is the same rule
`app.ts` states for `onError` and `routes/index.ts` for the validation hook. `OPEN_PATHS` is matched
with `===` on `c.req.path`, so `/health` does not exempt `/health-secret`.

**The two refusal arms are different on purpose, and the difference is the repo's caller-mistake /
Worker-bug split.** A missing, malformed or non-matching credential is a `401` in the shared
envelope, with **one message for absent and for wrong** — telling them apart is an oracle this API
has no reason to publish. A deployment whose own `SYNC_API_TOKEN` is unset, empty or shorter than
`MIN_TOKEN_LENGTH` instead **throws** and answers **`500 internal_error`**, with the detail only in
the Worker's log: that is not the caller's fault and not a state the Worker knows how to serve
under, and a `401` there would tell a human holding a curl that their credential was wrong when the
truth is that there is no secret for it to be wrong about. **An unarmed deployment is therefore a
`500`, not a `401`** — worth knowing before reading a log that says the gate is broken.

**The secret belongs to the deployment and is in no file in this repository.** Its three homes are
`backend/.dev.vars` (gitignored, for `wrangler dev`), `ios/App/Config/Whoopsy.local.xcconfig`
(gitignored, for the app) and `wrangler secret put SYNC_API_TOKEN`. It is declared
`SYNC_API_TOKEN?: string` in `src/env.ts` — **optional** because `DB` and `EXPORTS` are declared in
`wrangler.toml` and always present while a secret never is, and because testing `=== undefined`
against a `string` does not compile. **Set it before deploying**: `wrangler deploy` does not fail on
a missing one, it ships a Worker that refuses everything.

**What the gate buys is bounded and is not authentication.** It stops scanners, bots and drive-by
requests against a discoverable `*.workers.dev` hostname. The same string is compiled into the app
binary, so anyone who extracts it has the same access the owner does. There is no `accounts` table,
no registration and no revocation; `X-Whoopsy-User-Id` remains a self-declared partition name that
the Worker hashes and never stores, and the gate checks the credential **first** — a bad token
beside a malformed query is a `401` and never a `400`, because a `401` from middleware bypasses
`validationHook` entirely.

**The repo is a monorepo, and this file is about the app in it.** The SwiftPM package and `Whoopsy.xcodeproj` live under `ios/`; `backend/` is a Cloudflare Worker (Hono in front of D1 + R2) that carries **eight resources the whole way** — `biometricSamples` at `/v1/biometric-samples/{id}`, `recoveries` at `/v1/recoveries/{date}`, `workouts` at `/v1/workouts/{id}`, `strains` at `/v1/strains/{date}`, `sleeps` at `/v1/sleeps/{date}`, `stepCounts` at `/v1/step-counts/{date}`, `receptiveInactivities` at `/v1/receptive-inactivities/{id}` and `userProfiles` at `/v1/profile`, each from the route through the service and the repository into its own D1 migration — plus `GET /health` and the OpenAPI document generated from those route definitions and written to `shared/openapi.json`. **Four of the eight are date-keyed with one row per day and the other four are not**: `recoveries`, `strains`, `sleeps` and `stepCounts` are keyed on their date; `workouts` is keyed on a session id and is an aggregate of three tables on the wire; `receptiveInactivities` is keyed on an id too, for `workouts`' reason and with none of its aggregate — one table, no children, no `seq`; and `biometricSamples` is keyed on an id as well, with no children either, but it is the one resource here whose **read window is a pair of instants rather than a count of days**; and `userProfiles` is the one resource here with **no key of any kind on its path** — a profile is a singleton, so a partition holds one row or none, and its whole surface is `GET /v1/profile` and `PUT /v1/profile`, which makes it the only entry in the published document that is a resource's entire path set rather than a third of one. It is also the only mount here whose segment is **singular** (the other seven name collections) and the only resource whose service refuses nothing, so there is no `UserProfileError` beside the seven refusal classes — a rule it does have, `restingHeartRate` strictly below `maxHeartRate`, is published on the write body's `.refine()` rather than restated in a service, on the same reasoning that puts `SleepWriteSchema`'s `endsAfterItStarts` on its body alone. `biometricSamples` is the widest table in this Worker by three orders of magnitude and it is the reason the family has a window measured in seconds at all: a day of it is up to 86,400 rows, so a day-counted window would make "give me last month" a read no Worker should be asked for, and `MAX_BIOMETRIC_SAMPLE_WINDOW_SECONDS` is `604_800` — a week — in this resource's own unit rather than an alias of the four day-keyed windows' `MAX_WINDOW_DAYS`. **It is also the one adapter here that handles JSON**: `rr_intervals_ms` holds a `[Double]` as text and is published on the wire as an array of numbers rather than as the string that is secretly JSON, because a series of intervals has no interior a decoder would have to agree about — which is exactly why `sleep_stages`, whose segments carry interior `Date`s, stays an opaque blob. And **it is the one resource here whose identity is the client's derivation rather than a key this app's storage already had**: the phone's local row key is an autoincrement in that device's own SQLite that never reaches its entity, so two devices in one partition would both mint from 1 and silently overwrite each other; the wire id is therefore a client-derived string, the Worker validates the shape and publishes the requirement that it be **deterministic** — so that a replay is an upsert rather than a second row — and deliberately does not reproduce a recipe, because a server that derived an id would be a second implementation of the client's identity, free to disagree with the id the client asks for on its next read. **`receptiveInactivities` is the resource the iOS half already had and the Worker did not**, and it is the one resource whose port carries a method the Worker deliberately has no endpoint for: `ReceptiveInactivityRepository.delete(_ id: UUID)` is declared at `ios/Sources/Whoopsy/Domain/Repositories/PresentationRepositories.swift:133` while **no route in this Worker deletes anything** — `WorkoutRepository.delete(_:)` is at line 76 of that same file and has no counterpart here either, so it is a standing convention rather than an omission on this resource, and the reason a reader arriving from either port will not find a delete path to call. **`/v1/step-counts`, `/v1/receptive-inactivities` and `/v1/biometric-samples` are the three kebab-case paths, and each is the one resource whose URL, type and table are spelled differently**: the resource's own type is `StepCount` and its D1 table is `step_counts`, so `/v1/stepCounts` and `/v1/step_counts` are both plausible readings of the same resource and both name a mount that does not exist — and `biometricSamples` adds a third reading from the other side, being the only one of the three whose type is *singular* while its path is plural, so `/v1/biometric-sample` is as plausible as what is mounted. That is why the served document's path list is asserted exhaustively rather than derived from the mount table. **The mount is also where this resource teaches the rule that the two orders are different**: it is mounted first among the `/v1/*` entries because `b` sorts before `r`, while the identifier `biometricSampleRoutes` would be appended last by anyone adding a resource conventionally — and `routes/index.ts` carries that argument at the mount itself. `sleeps` is the one that looks most like a copy of a sibling and is not: it is `strains`' shape — keyed on the day, an upsert, a range read, a `POST /batch` chunk — carrying `recoveries`' absence rule, because it has no `hasMeasurement` column and therefore no second kind of row, and its day is the night's **wake** day. `stepCounts` is that shape a second time, and it is the narrowest of the seven: it copies `sleeps` and not `strains` — keyed on the day, an upsert, a range read, a `POST /batch` chunk, no stored `hasMeasurement` flag and therefore no second kind of row — while having **no `source` and no nullable column at all**. Steps have exactly one producer, the strap, and a day is routinely fed by both a live stream and a banked drain, so a per-row provenance label could not be written honestly; and `measuredSeconds` is the field that separates a measured day of no walking from a day nothing measured, which is why a default on it would publish the second as the first. `receptiveInactivities` is the one resource whose *shape* is decided by a nullable pair rather than by a flag: an entry carries a `name` and an optional `startedAt` and nothing else, because with no `endedAt` it has no span — it cannot `covers(_:)` a day, cannot be in progress and cannot aggregate into a zone block — and `note` and `startedAt` are **nullable rather than optional** on the wire, so the two absences have one spelling and `""` is refused rather than accepted as a third state. Its ordering is `date ASC, started_at ASC NULLS LAST, name ASC`, where `NULLS LAST` is the clause a naive port drops and the one this resource cannot afford to lose: SQLite sorts NULL *first* ascending and the untimed entry is the *majority* case — all 62 of the app's bundled rows are untimed — so without it every imported entry would be drawn above the timed ones on its own day. **The Worker used to be ahead of the client on the last four resources, and it no longer is.** The iOS half's `CloudSync` port covers all seven, `Data/Networking/` holds a wire mapper per resource and `Domain/Repositories/` a `*SyncStore` per table — so a sentence saying "three resources" is describing the client's sync as it was and one saying "eight" is describing what this Worker carries, and the count that is current is **seven on both sides**. **The two halves are still not equal, and the difference is one resource and one direction.** `biometricSamples` is the Worker's eighth and the client carries no part of it, because its window is measured in seconds rather than days and it takes its own control. And of the seven the client does carry, all seven now read and write back — the four this loop added, `sleeps`, `stepCounts`, `receptiveInactivities` and the profile, grew read methods and read-back decorators beside the three the client already carried (`recoveries`, `workouts` and `strains`), and `CloudRecoveryRepository` is the first of seven local-first decorators, one per resource. **`userProfiles` is the one of the four whose client half was not a copy of a sibling**, because its mapper mints the `"primary"` id the app's local row carries and converts its `.datetime` birthday column to the day key the wire publishes. `shared/openapi.json` is the contract the two agree on, and it is now an **output** rather than a hand-written stub. Paths below are written **from the repo root**, so anything naming a real file carries the `ios/` prefix; the unprefixed layer names (`Data/BLE/`, `Core/Math/`, `Presentation/DesignSystem/`, `App/DependencyInjection/`) are shorthand for paths inside `ios/Sources/Whoopsy/` and were never root-resolvable.

## Running it

From `backend/`:

```bash
npm ci                     # or `npm install` the first time
npm run typecheck          # tsc --noEmit, three projects
npm test                   # the real Worker against a local D1
npm run openapi            # rewrites ../shared/openapi.json
make -C .. backend-check   # all of the above, failing if the contract is stale
```

**`npm test` and `wrangler dev` use two different databases.** The suite builds its own from
`migrations/` on every run; `wrangler dev` keeps one under `backend/.wrangler/state` that starts
empty. A fresh checkout that curls the dev server gets `500` with `no such table: recoveries` until:

```bash
npx wrangler d1 migrations apply whoopsy-sync --local
npx wrangler dev --port 8787
```

**And it answers `500` on every `/v1` request until `backend/.dev.vars` holds a secret.** Copy
`backend/.dev.vars.example` to `.dev.vars` and put the same `SYNC_API_TOKEN` the app's gitignored
xcconfig carries after the `=`. Without it the gate throws rather than returning `401`; `GET /health`
and `GET /openapi.json` answer either way.

To exercise it by hand:

```bash
curl -s localhost:8787/v1/recoveries?days=2 \
  -H "Authorization: Bearer $SYNC_API_TOKEN" -H "X-Whoopsy-User-Id: $ANY_32_CHAR_STRING"
```

The check that the served contract and the committed one are one document is a shell step rather than
a spec, because a Worker has no filesystem:

```bash
curl -s localhost:8787/openapi.json | grep -v '"url"' | diff - <(grep -v '"url"' ../shared/openapi.json) \
  && echo IDENTICAL
```

`grep` drops `servers[0].url`, the only line the two readings are allowed to disagree about: the dev
server names its own origin and the committed file names `/`, the OpenAPI relative form. Everything
else comes out of one `getOpenAPI31Document` call.

**Local development runs late-2024 `workerd` while a deployment runs `compatibility_date`'s
semantics.** `wrangler` is pinned to `3.95.0` because that is what
`@cloudflare/vitest-pool-workers` pairs with. A flag from after `2024-12-05` would be green locally
and wrong deployed; moving to wrangler 4 is a coordinated bump and not this pass.

## Deployment

The Worker is deployed; the hostname is deliberately written down nowhere in this repository. The
committed `shared/openapi.json` carries `/` as `servers[0].url` — the OpenAPI relative form — so a
fork regenerates the contract unchanged and nothing breaks. A deployment names its own origin in the
document it serves at `GET /openapi.json`.

**Set `SYNC_API_TOKEN` before deploying** — `wrangler deploy` does not fail on a missing one, it ships
a Worker that refuses every request:

```bash
npx wrangler secret put SYNC_API_TOKEN
npx wrangler deploy
```

The D1 database and R2 bucket are created once per account; a fresh clone needs neither
`wrangler d1 create` nor `wrangler r2 bucket create` — only `wrangler d1 migrations apply
whoopsy-sync --remote` if it wants the remote schema, `--local` for `wrangler dev`, and its **own**
`SYNC_API_TOKEN`. Two deployments sharing one secret would share rows.

## Configuring the app

The app's half is two values in `ios/App/Config/Whoopsy.local.xcconfig` (gitignored):

| Setting | What it is |
| :--- | :--- |
| `WHOOPSY_API_BASE_URL` | The deployment's origin. Expands into `WHOOPSYAPIBaseURL` in `Info.plist` |
| `WHOOPSY_API_TOKEN` | The deployment's shared secret, sent as `Authorization: Bearer` |

Both or neither: a hostname alone would open a socket on every read to collect a `401`.

**An xcconfig value containing `//` is truncated there**, because `//` starts a comment. An
`https://` URL must therefore be written with an empty `$()` standing in for the second slash:

```
WHOOPSY_API_BASE_URL = https:/$()/whoopsy-sync.your-account-subdomain.workers.dev
```

Get it wrong and the build stays green while the base URL is the string `https:` — a runtime
`NSURLSession` failure with nothing at build time to suggest why.

```bash
cp ios/App/Config/Whoopsy.local.xcconfig.example ios/App/Config/Whoopsy.local.xcconfig
openssl rand -base64 32 | tr '+/' '-_' | tr -d '='
# edit the copy: both keys, plus the Mapbox token if you want the offline map
```

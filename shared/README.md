# shared/

The API contract between the Worker in `backend/` and the iOS client, **one folder per resource**.

```
health/                 GET  /health
recoveries/             /v1/recoveries
sleeps/                 /v1/sleeps
strains/                /v1/strains
workouts/               /v1/workouts
step-counts/            /v1/step-counts
receptive-inactivities/ /v1/receptive-inactivities
profile/                /v1/profile
biometric-samples/      /v1/biometric-samples   (served, not synced — the client keeps these)
```

Each `openapi.json` is a **valid OpenAPI document in its own right**: the paths under that segment
and only the schemas those paths reach. They overlap on shared schemas by design, so each file can
be read, validated or pasted into an editor on its own.

**There is deliberately no whole-document file here.** The complete contract is ~250 KB; a deployment
serves it at `GET /openapi.json`, built from the same route definitions as these slices.

**Everything in this folder is generated** — `npm --prefix backend run openapi` rewrites all of it.
Never hand-edit a slice; edit the route, DTO or schema in `backend/` and regenerate. A stale folder
is deleted on the next run, so a renamed resource cannot leave two contracts behind.

# `tmp/` — testing scratch

**This directory is for testing. Nothing in it is part of the app, and none of it is committed**
(see the `tmp/` block in `../.gitignore`; only this README is tracked, so that a clone knows what
the folder is).

It exists so that verification output lands *inside the repo* rather than in the machine's `/tmp`.
Write here — not to `/tmp` — when capturing a screenshot, dumping a build log, or scribbling a
throwaway probe.

| Folder | Holds | Safe to delete? |
| :--- | :--- | :--- |
| `screenshots/` | Simulator captures (`xcrun simctl io … screenshot`) taken to verify a change | Yes — regenerable by re-running the capture |
| `scratch/` | One-off probe sources (`swift tmp/scratch/probe.swift`-style) and build logs | Yes — every file here is disposable by definition |
| `backups/` | SQLite copies of the simulator's data container, taken before a risky change | **Careful** — the imported export and any recorded sessions exist nowhere else |
| `build/` | Build output. SwiftPM's scratch path (`scripts/test.sh`) and Xcode's derived data (`make ios`) | Yes — `make clean` removes it and the next build repopulates it |

## Build output paths

Both are pointed here already, so nothing writes outside the repo:

```bash
scripts/test.sh          # swift build --scratch-path tmp/build/verify
                         #   override with WHOOPSY_SCRATCH=/somewhere/else
make ios                 # xcodebuild -derivedDataPath tmp/build/whoopsy-dd
make clean               # rm -rf tmp/build
```

## Two things worth knowing before you delete `build/`

- **`scripts/test.sh` needs a scratch path that is not `.build`.** The default build directory
  accumulates object files from since-deleted sources and the link then fails with
  `symbol(s) not found` for symbols nothing declares any more. That is why the path exists at all,
  and it is safe to delete between runs.
- **`make test` links the test runner against objects inside `tmp/build/verify`.** Deleting it
  mid-session just means the next `make test` rebuilds — slower, not broken.

## The backups are real data

`backups/*.sqlite` are copies of the simulator app's container, and the container holds the
WHOOP export that was imported into it. Per the repo's standing rule, that is a real person's
physiological record — it is gitignored for the same reason `ios/Sources/Whoopsy/Data/Resources/*.csv`
is, and it is the one thing in this folder that is not regenerable.

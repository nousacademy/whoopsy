#!/bin/bash
#
# Build and run the Whoopsy test suite. This supersedes `run_tests.sh`, which linked stale objects
# out of `.build` and omitted the `-fmodule-map-file` flag, so it died with `missing required module
# 'CSQLite'` before it ever reached a test.
#
#   ./scripts/test.sh              # all 21 sections
#   ./scripts/test.sh 13 15        # §13 and §15 only
#   ./scripts/test.sh 13,15        # same thing
#   make test SECTIONS=13,15       # same thing, via the Makefile
#
# The runner prints one machine-readable line at the end:
#
#   SUITE sections=1,...,21 assertions=1928 failed=0 exit=0
#
# Read that line rather than the `✓` scrollback. This suite has no test discovery, so a section that
# stopped running looks exactly like one that passed — `sections=` is the field that catches it, and
# `assertions=` the field that catches a section that ran but stopped asserting.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The SwiftPM package lives under `ios/` — this is a monorepo, and the backend's Worker sits beside
# it in `backend/`. Named once here so a future move is one line rather than three.
package_root="$repo_root/ios"
# Under the repo's own `tmp/` rather than the machine's `/tmp`, and gitignored — see
# `tmp/README.md`. `WHOOPSY_SCRATCH` still overrides it.
scratch="${WHOOPSY_SCRATCH:-$repo_root/tmp/build/verify}"
runner="$scratch/WhoopsyTestRunner"

# **Absolute, and that is load-bearing.** `#filePath` in the runner is whatever path is handed to
# swiftc, and the suite's `packageRoot()` walks up from it to find the bundled export. A relative path
# makes the root it computes depend on the caller's working directory, so §11–§21 each fail with a
# message that reads like a broken import. An absolute path removes that failure class outright, which
# is why the suite no longer has to be run from the repo root.
#
# `WHOOPSY_PACKAGE_ROOT` is exported beside it because `packageRoot()` prefers the override when it is
# set: the marker walk is there so the helper is depth-independent, and the export is what keeps the
# build's own absolute-path guarantee explicit rather than inferred.
main_swift="$package_root/Tests/WhoopsyTestRunner/main.swift"
export WHOOPSY_PACKAGE_ROOT="$package_root"

module_map="$package_root/.build/checkouts/GRDB.swift/Sources/CSQLite/module.modulemap"
if [ ! -f "$module_map" ]; then
    echo "Missing $module_map" >&2
    echo "Run 'swift build' once so SwiftPM checks GRDB out into ios/.build/." >&2
    exit 1
fi

# Sections may arrive as arguments or as an environment variable; arguments win.
if [ "$#" -gt 0 ]; then
    WHOOPSY_SECTIONS="$(printf '%s' "$*" | tr ' ' ',')"
fi
export WHOOPSY_SECTIONS="${WHOOPSY_SECTIONS:-}"

echo "▸ Building WhoopsyCore into $scratch ..."
# A scratch path, not `.build`: the default build directory accumulates object files from
# since-deleted sources (`MainTabView`, `SettingsView`, `TodayDashboardView`, `SwiftData*Repository`,
# …) and the link then fails with `symbol(s) not found` for symbols nothing declares any more.
swift build --package-path "$package_root" --scratch-path "$scratch"

# The platform triple is arm64-apple-macosx on Apple silicon and x86_64-apple-macosx on Intel. Read
# it rather than assuming, so this does not quietly become an Apple-silicon-only script.
triple_dir="$(cd "$scratch" && ls -d -- *-apple-macosx 2>/dev/null | head -1)"
if [ -z "$triple_dir" ]; then
    echo "No *-apple-macosx build directory under $scratch — did 'swift build' succeed?" >&2
    exit 1
fi

echo "▸ Linking the test runner ..."
# The test tree mirrors `Sources/Whoopsy/`, so the runner is no longer one file. `main.swift` must keep
# its name — Swift allows top-level statements only in a file called exactly that — and every other
# `.swift` under the test root is a declaration file, compiled alongside it in a deterministic order so
# that `#file`/`#line` reporting in a failure message stays stable run to run.
# Built with a read loop rather than `mapfile`, which is a bash 4 builtin: macOS ships bash 3.2 as
# `/bin/bash` and this script's shebang is `#!/bin/bash`, so `mapfile` is a "command not found".
runner_sources=()
while IFS= read -r source; do
    runner_sources+=("$source")
done < <(
    printf '%s\n' "$main_swift"
    find "$package_root/Tests/WhoopsyTestRunner" -name '*.swift' ! -name 'main.swift' | sort
)
swiftc \
    -I "$scratch/$triple_dir/debug/Modules" \
    -Xcc -fmodule-map-file="$module_map" \
    "$scratch/$triple_dir/debug/Whoopsy.build/"*.o \
    "$scratch/$triple_dir/debug/GRDB.build/"*.o \
    "${runner_sources[@]}" \
    -o "$runner"

echo "▸ Running${WHOOPSY_SECTIONS:+ sections $WHOOPSY_SECTIONS} ..."
echo
cd "$repo_root"
exec "$runner"

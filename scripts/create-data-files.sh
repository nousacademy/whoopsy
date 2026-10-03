#!/usr/bin/env bash
#
# create-data-files.sh — put the four bundled data files back on a fresh clone.
#
# `ios/Sources/Whoopsy/Data/Resources/` is gitignored in full, because what lives there is one real
# person's physiological record and a fasting tracker's history. That means a clone has no such
# directory, and `Package.swift` asks SwiftPM to `.process` four files inside it.
#
# This script writes **placeholder** versions of exactly those four — the ones `Package.swift`
# declares as resources, and nothing else:
#
#   Whoop/physiological_cycles.csv   26-column producer header, no rows
#   Whoop/sleeps.csv                 18-column producer header, no rows
#   Whoop/workouts.csv               17-column producer header, no rows
#   ZeroFasting/fasts.json           {"fast_data": []}
#
# `journal_entries.csv` is deliberately **not** created: it is the fourth CSV on disk and the only one
# that is unbundled and read by nothing. Neither are the other eighteen top-level keys of a Zero
# `biodata.json` — this app reads `fast_data` alone.
#
# ---------------------------------------------------------------------------------------------
# This script cannot destroy the record.
# ---------------------------------------------------------------------------------------------
#
# An export exists on this machine and nowhere else. So: **a file holding data is never overwritten
# by any flag.** A file is replaceable only when it is empty or byte-identical to the placeholder
# this script would write — i.e. when it is already this script's own output. Anything with rows in
# it is reported and left alone, and the script exits non-zero. To genuinely replace one, move it
# aside yourself (`mv`), which is an explicit and reversible act; the script will not do it for you.
#
# Usage:
#   scripts/create-data-files.sh            create what is missing, leave everything else alone
#   scripts/create-data-files.sh --check    report the state of all four, write nothing
#   scripts/create-data-files.sh --help

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
whoop_dir="$repo_root/ios/Sources/Whoopsy/Data/Resources/Whoop"
fasting_dir="$repo_root/ios/Sources/Whoopsy/Data/Resources/ZeroFasting"

# ---------------------------------------------------------------------------------------------
# The placeholder contents.
#
# The three CSV headers are transcribed verbatim from the producer's own header row — column names
# only, no data — so a placeholder is a file a real export's rows can be pasted under, and so that
# the parser's up-front column validation passes. The cycle file's header is the 26 columns
# `physiological_cycles.csv` carries; the sleep file's is the 18 `sleeps.csv` carries, `Nap`
# included; the workout file's is the 17 `workouts.csv` carries.
# ---------------------------------------------------------------------------------------------

cycle_csv() {
    cat <<'CSV'
Cycle start time,Cycle end time,Cycle timezone,Recovery score %,Resting heart rate (bpm),Heart rate variability (ms),Skin temp (celsius),Blood oxygen %,Day Strain,Energy burned (cal),Max HR (bpm),Average HR (bpm),Sleep onset,Wake onset,Sleep performance %,Respiratory rate (rpm),Asleep duration (min),In bed duration (min),Light sleep duration (min),Deep (SWS) duration (min),REM duration (min),Awake duration (min),Sleep need (min),Sleep debt (min),Sleep efficiency %,Sleep consistency %
CSV
}

sleep_csv() {
    cat <<'CSV'
Cycle start time,Cycle end time,Cycle timezone,Sleep onset,Wake onset,Sleep performance %,Respiratory rate (rpm),Asleep duration (min),In bed duration (min),Light sleep duration (min),Deep (SWS) duration (min),REM duration (min),Awake duration (min),Sleep need (min),Sleep debt (min),Sleep efficiency %,Sleep consistency %,Nap
CSV
}

workout_csv() {
    cat <<'CSV'
Cycle start time,Cycle end time,Cycle timezone,Workout start time,Workout end time,Duration (min),Activity name,Activity Strain,Energy burned (cal),Max HR (bpm),Average HR (bpm),HR Zone 1 %,HR Zone 2 %,HR Zone 3 %,HR Zone 4 %,HR Zone 5 %,GPS enabled
CSV
}

fasts_json() {
    printf '{"fast_data": []}\n'
}

# ---------------------------------------------------------------------------------------------
# The four, in the order `Package.swift` declares them.
# ---------------------------------------------------------------------------------------------

paths=(
    "$whoop_dir/physiological_cycles.csv"
    "$whoop_dir/sleeps.csv"
    "$whoop_dir/workouts.csv"
    "$fasting_dir/fasts.json"
)

writer_for() {
    case "$(basename "$1")" in
        physiological_cycles.csv) cycle_csv ;;
        sleeps.csv)               sleep_csv ;;
        workouts.csv)             workout_csv ;;
        fasts.json)               fasts_json ;;
        *) echo "create-data-files: no placeholder defined for $1" >&2; exit 2 ;;
    esac
}

# The columns the parser validates up front. A file missing any of these fails loudly at import
# rather than importing a table of nils, which is the whole reason the check exists.
required_for() {
    case "$(basename "$1")" in
        physiological_cycles.csv) printf '%s\n' "Cycle start time" "Cycle timezone" "Wake onset" ;;
        sleeps.csv)               printf '%s\n' "Cycle start time" "Cycle timezone" "Wake onset" "Nap" ;;
        workouts.csv)             printf '%s\n' "Cycle start time" "Cycle timezone" "Workout start time" "Workout end time" ;;
    esac
}

is_json() { [[ "$(basename "$1")" == "fasts.json" ]]; }

relative() { printf '%s' "${1#"$repo_root"/}"; }

# "placeholder"  — absent, empty, or already what this script writes: safe to (re)write
# "data"         — holds rows: never touched, by any flag
classify() {
    local path="$1"
    [[ -s "$path" ]] || { printf 'placeholder'; return; }

    if is_json "$path"; then
        # Whitespace-insensitive, so a `json.dumps(…, indent=4)` file holding an empty array is
        # still recognised as empty rather than mistaken for an export.
        if [[ "$(tr -d '[:space:]' < "$path")" == '{"fast_data":[]}' ]]; then
            printf 'placeholder'
        else
            printf 'data'
        fi
        return
    fi

    # A CSV: replaceable only while it is its header line and nothing else.
    local lines
    lines="$(awk 'NF { n++ } END { print n + 0 }' "$path")"
    if (( lines <= 1 )); then printf 'placeholder'; else printf 'data'; fi
}

check_one() {
    local path="$1" label status problem=""

    if [[ ! -e "$path" ]]; then
        printf '  %-12s %s\n' "MISSING" "$(relative "$path")"
        return 1
    fi
    if [[ ! -s "$path" ]]; then
        printf '  %-12s %s  (empty)\n' "EMPTY" "$(relative "$path")"
        return 1
    fi

    if [[ "$(classify "$path")" == "data" ]]; then label="DATA"; else label="PLACEHOLDER"; fi

    if is_json "$path"; then
        grep -qF '"fast_data"' "$path" || problem='no "fast_data" key'
    else
        local column
        while IFS= read -r column; do
            if ! head -1 "$path" | grep -qF -- "$column"; then
                problem="no \"$column\" column"
                break
            fi
        done < <(required_for "$path")
    fi

    if [[ -n "$problem" ]]; then
        printf '  %-12s %s  (%s)\n' "$label" "$(relative "$path")" "$problem"
        return 1
    fi
    printf '  %-12s %s\n' "$label" "$(relative "$path")"
    return 0
}

mode="create"
case "${1:-}" in
    --check) mode="check" ;;
    --help|-h)
        # The header comment, from line 2 down to the first line that is not one. Written as a
        # range rather than `sed -n '3,34p'` so that editing the comment cannot silently truncate
        # the help it prints — the previous fixed range cut off before `Usage:`.
        awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
        exit 0
        ;;
    "") ;;
    *) echo "create-data-files: unknown argument '$1' (try --help)" >&2; exit 2 ;;
esac

if [[ "$mode" == "check" ]]; then
    echo "Data files under $(relative "$whoop_dir")/ and $(relative "$fasting_dir")/:"
    failures=0
    for path in "${paths[@]}"; do
        check_one "$path" || failures=$((failures + 1))
    done
    echo
    if (( failures )); then
        echo "$failures of ${#paths[@]} not usable — run scripts/create-data-files.sh"
        exit 1
    fi
    echo "All ${#paths[@]} present. Run scripts/create-data-files.sh if any say PLACEHOLDER and you"
    echo "have a real export to drop in — a placeholder builds, but imports nothing."
    exit 0
fi

mkdir -p "$whoop_dir" "$fasting_dir"

created=0; kept=0; refused=0
for path in "${paths[@]}"; do
    if [[ -e "$path" ]] && [[ "$(classify "$path")" == "data" ]]; then
        printf 'kept     %s  (holds data — not touched)\n' "$(relative "$path")"
        refused=$((refused + 1))
        continue
    fi

    if [[ -s "$path" ]]; then
        printf 'kept     %s  (already the placeholder)\n' "$(relative "$path")"
        kept=$((kept + 1))
        continue
    fi

    writer_for "$path" > "$path"
    printf 'created  %s\n' "$(relative "$path")"
    created=$((created + 1))
done

echo
echo "$created created, $kept already present."
if (( refused )); then
    echo
    echo "$refused file(s) above hold data and were left exactly as they were. This script will not"
    echo "overwrite an export — it is the only copy. Move one aside yourself if you really mean to."
fi

echo
echo "Next: make build   (the four are what Package.swift processes; journal_entries.csv is not one"
echo "                    of them and is deliberately not created)"

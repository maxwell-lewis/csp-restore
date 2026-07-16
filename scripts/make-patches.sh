#!/usr/bin/env bash
#
# make-patches.sh — MAINTAINER TOOL (not run by end users)
#
# Regenerates patches/ by diffing the known-good working port against a fresh,
# unmodified decompile of the reference IPA. The diffs contain only OUR changes
# — not Bungie/Harebrained source — which is what keeps this repo clean.
#
# The baseline is produced by calling `convert.py --decompile-only`, i.e. the
# EXACT code path an end user runs. If the baseline were generated any other
# way (a hand-rolled java loop, a different redirect, different encoding
# handling), the two decompiles could differ and every file would look
# "changed" — silently producing a patch per file and effectively embedding
# the whole game in the repo.
#
# Usage:
#   scripts/make-patches.sh <reference.ipa> <working-port-dir>
#
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IPA="${1:?usage: make-patches.sh <reference.ipa> <working-port-dir>}"
WORKING="${2:?usage: make-patches.sh <reference.ipa> <working-port-dir>}"
PATCHDIR="$REPO/patches"
OVERLAY="$REPO/port-overlay"
CONVERT="$REPO/converter/convert.py"
UNLUAC="$REPO/converter/tools/unluac.jar"

IPA="$(cd "$(dirname "$IPA")" && pwd)/$(basename "$IPA")"
WORKING="$(cd "$WORKING" && pwd)"

# --- preflight: fail loudly, never silently ---------------------------------
[ -f "$IPA" ]     || { echo "ERROR: IPA not found: $IPA" >&2; exit 1; }
[ -d "$WORKING" ] || { echo "ERROR: working dir not found: $WORKING" >&2; exit 1; }
[ -f "$UNLUAC" ]  || { echo "ERROR: unluac.jar not found: $UNLUAC" >&2; exit 1; }
[ -f "$CONVERT" ] || { echo "ERROR: convert.py not found: $CONVERT" >&2; exit 1; }

if ! command -v java >/dev/null 2>&1; then
    cat >&2 <<'EOF'
ERROR: `java` is not on PATH, and unluac needs it to decompile.

Without java the baseline decompile would be EMPTY, and every game file would
look like a brand-new addition — producing one bogus patch per file. Refusing
to run.

  Debian/Ubuntu:  sudo apt install default-jre
  Arch:           sudo pacman -S jre-openjdk
  Fedora:         sudo dnf install java-latest-openjdk-headless
EOF
    exit 1
fi
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not on PATH" >&2; exit 1; }
command -v diff    >/dev/null 2>&1 || { echo "ERROR: diff not on PATH" >&2; exit 1; }

echo "== Reference IPA fingerprint =="
sha256sum "$IPA" | awk '{print $1}'
echo "  (paste this into SUPPORTED_IPAS in converter/convert.py)"
echo

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
BASE="$WORK/baseline"

echo "== Decompiling baseline via convert.py --decompile-only =="
echo "   (same code path the end user runs — guarantees the diffs are real)"
if ! python3 "$CONVERT" --ipa "$IPA" --out "$BASE" --decompile-only; then
    echo "ERROR: baseline decompile failed. Not writing any patches." >&2
    exit 1
fi

NBASE=$(find "$BASE" -name '*.lua' -type f -size +0 | wc -l | tr -d ' ')
if [ "$NBASE" -lt "${CSP_MIN_BASELINE:-100}" ]; then
    echo "ERROR: baseline only has $NBASE non-empty Lua files — that's not a" >&2
    echo "       real decompile. Refusing to generate patches." >&2
    exit 1
fi
echo "   baseline: $NBASE non-empty Lua files"
echo

echo "== Generating patch series =="
mkdir -p "$PATCHDIR"
rm -f "$PATCHDIR"/*.patch
cat > "$PATCHDIR/series" <<'HDR'
# Patch series — applied in order by converter/convert.py over the fresh
# decompile of the user's own IPA.
#
# These unified diffs are this project's original contribution: they contain
# only the changes we made (plus the minimal surrounding context `patch`
# needs to anchor them). They are regenerated with:
#     scripts/make-patches.sh <reference.ipa> <working-port-dir>
HDR

count=0
skipped_empty=0
while IFS= read -r -d '' wf; do
    rel="${wf#"$WORKING"/}"
    case "$rel" in
        boot.lua|run.sh|README.md|Pirates/mock/*) continue ;;
        Pirates/data/*) continue ;;
    esac

    bf="$BASE/$rel"
    [ -f "$bf" ] || continue

    if [ ! -s "$bf" ]; then
        echo "  !! baseline empty for $rel — skipping (decompile issue)"
        skipped_empty=$((skipped_empty+1))
        continue
    fi

    if ! diff -q "$bf" "$wf" >/dev/null 2>&1; then
        patchname="$(echo "$rel" | tr '/' '_').patch"
        diff -u --label "a/$rel" --label "b/$rel" "$bf" "$wf" \
            > "$PATCHDIR/$patchname" || true
        echo "$patchname" >> "$PATCHDIR/series"
        count=$((count+1))
        echo "  patch: $rel"
    fi
done < <(find "$WORKING" -name '*.lua' -print0)

echo
echo "== Copying pure-original files into port-overlay/ =="
for f in boot.lua run.sh; do
    if [ -f "$WORKING/$f" ]; then
        cp "$WORKING/$f" "$OVERLAY/$f"
        echo "  overlay: $f"
    fi
done
if [ -d "$WORKING/Pirates/mock" ]; then
    mkdir -p "$OVERLAY/Pirates/mock"
    cp "$WORKING"/Pirates/mock/*.lua "$OVERLAY/Pirates/mock/" 2>/dev/null || true
    echo "  overlay: Pirates/mock/*"
fi

echo
echo "== Result =="
echo "  patches written: $count"
[ "$skipped_empty" -gt 0 ] && echo "  skipped (empty baseline): $skipped_empty"

if [ "$count" -gt 60 ]; then
    cat >&2 <<EOF

WARNING: $count patches is far more than expected (~15).

That usually means the baseline decompile does not match the source your
working port was built from — e.g. a different IPA build, or a different
unluac. Inspect a patch for a file you never touched, e.g.:

    head -20 $PATCHDIR/Pirates_rollsheet.lua.patch

If it shows '@@ -0,0 +1,N @@' (everything added), the baseline was empty.
If it shows unrelated real changes, the IPA build is wrong.

DO NOT COMMIT these patches until the count looks sane.
EOF
    exit 1
fi

echo
echo "Next:"
echo "  1. paste the sha256 above into converter/convert.py SUPPORTED_IPAS"
echo "  2. scripts/verify.sh \"\$IPA\" --with-engine"
echo "  3. commit patches/ and port-overlay/ (never the baseline)"

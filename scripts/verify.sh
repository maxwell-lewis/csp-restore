#!/usr/bin/env bash
#
# verify.sh — clean-room round-trip check.
#
# Proves that a stranger with nothing but this repository and their own IPA can
# reproduce a working game. Run this BEFORE pushing the repo public.
#
# It deliberately does NOT touch your working port tree. It copies the repo to
# a scratch directory, runs the pipeline exactly as an end user would, and
# checks the result.
#
# Usage:
#   scripts/verify.sh <reference.ipa> [--with-engine] [--play]
#
#     --with-engine   also build the MOAI engine from source (slow: ~10-30 min).
#                     Without this, the engine build is skipped and only the
#                     data conversion is verified.
#     --play          launch the game at the end (needs a display).
#
# Exit code 0 = the repo is self-sufficient.
#
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IPA="${1:-}"
shift || true

WITH_ENGINE=0
PLAY=0
for arg in "$@"; do
    case "$arg" in
        --with-engine) WITH_ENGINE=1 ;;
        --play)        PLAY=1 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

if [ -z "$IPA" ] || [ ! -f "$IPA" ]; then
    cat >&2 <<EOF
usage: scripts/verify.sh <reference.ipa> [--with-engine] [--play]

Runs the full end-user flow against a scratch copy of this repo to confirm it
is self-sufficient (i.e. someone who clones it can rebuild the game).
EOF
    exit 2
fi
IPA="$(cd "$(dirname "$IPA")" && pwd)/$(basename "$IPA")"

PASS=0
FAIL=0
ok()   { echo "  [ ok ] $*"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
note() { echo "  ....   $*"; }

echo "=============================================="
echo " csp-restore clean-room verification"
echo "=============================================="
echo "repo: $REPO"
echo "ipa:  $IPA"
echo

# ---------------------------------------------------------------------------
echo "[1/7] Host dependencies"
# ---------------------------------------------------------------------------
need_bin() {
    if command -v "$1" >/dev/null 2>&1; then ok "$1 found"; else bad "$1 MISSING ($2)"; fi
}
need_bin python3 "run the converter"
need_bin java    "run unluac (decompiler)"
need_bin ffmpeg  "transcode audio"
need_bin patch   "apply the patch series"
need_bin unzip   "extract the IPA"

if python3 -c "import texture2ddecoder" 2>/dev/null; then
    ok "python: texture2ddecoder"
else
    bad "python: texture2ddecoder MISSING (pip install texture2ddecoder)"
fi
if python3 -c "import PIL" 2>/dev/null; then
    ok "python: pillow"
else
    bad "python: pillow MISSING (pip install pillow)"
fi

if [ "$WITH_ENGINE" -eq 1 ]; then
    need_bin cmake "build the MOAI engine"
    need_bin git   "clone the MOAI source"
fi
echo

# ---------------------------------------------------------------------------
echo "[2/7] Repo self-sufficiency (no asset leakage, required files present)"
# ---------------------------------------------------------------------------
[ -f "$REPO/converter/convert.py" ]        && ok "converter/convert.py"        || bad "converter/convert.py missing"
[ -f "$REPO/converter/pvr_decode.py" ]     && ok "converter/pvr_decode.py"     || bad "converter/pvr_decode.py missing"
[ -f "$REPO/converter/tools/unluac.jar" ]  && ok "converter/tools/unluac.jar"  || bad "converter/tools/unluac.jar missing (scripts/fetch-unluac.sh)"
[ -f "$REPO/port-overlay/boot.lua" ]       && ok "port-overlay/boot.lua"       || bad "port-overlay/boot.lua missing"
[ -f "$REPO/port-overlay/run.sh" ]         && ok "port-overlay/run.sh"         || bad "port-overlay/run.sh missing"
[ -f "$REPO/patches/series" ]              && ok "patches/series"              || bad "patches/series missing"

# The repo must NOT contain any game assets or decompiled game source.
leak=0
while IFS= read -r -d '' f; do
    leak=1; echo "  [FAIL] asset/source leak in repo: ${f#"$REPO"/}"
done < <(find "$REPO" \
            -path "$REPO/.git" -prune -o \
            \( -name '*.ipa' -o -name '*.pvr' -o -name '*.pv1' \
               -o -name 'crimson.tar.gz' \
               -o -path '*/Pirates/img/*' \
               -o -path '*/Pirates/particles/*' \
               -o -path '*/Pirates/img_iphone/*' \
               -o -path '*/Pirates/levels/*' \
               -o -path '*/Pirates/ships/*' \
               -o -path '*/Pirates/sailors/*' \
               -o -path '*/Pirates/music/*' \
               -o -path '*/Pirates/sfx/*' \) -type f -print0)
if [ "$leak" -eq 0 ]; then
    ok "no game assets or decompiled source committed"
else
    FAIL=$((FAIL+1))
fi

# Count real (non-comment) entries in the patch series.
# NB: grep exits 1 when nothing matches (an all-comments series is the normal
# pre-release state), so guard it or `set -e` will kill the run here.
NPATCH=$(grep -cvE '^\s*(#|$)' "$REPO/patches/series" 2>/dev/null || true)
NPATCH=${NPATCH:-0}
if [ "$NPATCH" -eq 0 ]; then
    note "patch series is EMPTY — run scripts/make-patches.sh first."
    note "The conversion will still be verified, but the resulting game will"
    note "be an unpatched decompile and will NOT play correctly."
else
    ok "patch series has $NPATCH patches"
fi
echo

# ---------------------------------------------------------------------------
echo "[3/7] Scratch copy of the repo (simulating a fresh clone)"
# ---------------------------------------------------------------------------
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
CLONE="$SCRATCH/clone"
mkdir -p "$CLONE"
# Copy only what git would track (respecting .gitignore-ish exclusions).
tar -C "$REPO" \
    --exclude='.git' --exclude='build' --exclude='__pycache__' \
    --exclude='*.pyc' -cf - . | tar -C "$CLONE" -xf -
ok "scratch clone at $CLONE"
echo

# ---------------------------------------------------------------------------
echo "[4/7] IPA fingerprint / supported-build gate"
# ---------------------------------------------------------------------------
HASH="$(python3 "$CLONE/converter/convert.py" --fingerprint "$IPA")"
note "sha256: $HASH"
# grep exits 1 when the hash isn't registered yet — expected before release,
# so it must not trip `set -e`.
if grep -q "$HASH" "$CLONE/converter/convert.py" 2>/dev/null; then
    ok "IPA is registered in SUPPORTED_IPAS"
    GATE_ARGS=()
else
    bad "IPA is NOT in SUPPORTED_IPAS — paste this hash into converter/convert.py"
    note "continuing with --skip-checksum so the rest can still be verified"
    GATE_ARGS=(--skip-checksum)
fi
echo

# ---------------------------------------------------------------------------
echo "[5/7] Conversion (the exact end-user command)"
# ---------------------------------------------------------------------------
OUT="$SCRATCH/game"
LOG="$SCRATCH/convert.log"
if python3 "$CLONE/converter/convert.py" \
        --ipa "$IPA" --out "$OUT" "${GATE_ARGS[@]}" >"$LOG" 2>&1; then
    ok "converter exited 0"
else
    bad "converter FAILED — last 20 lines:"
    tail -20 "$LOG" | sed 's/^/         /'
fi
echo

# ---------------------------------------------------------------------------
echo "[6/7] Output sanity"
# ---------------------------------------------------------------------------
check_file() { [ -f "$OUT/$1" ] && ok "$1" || bad "$1 missing from output"; }
check_file boot.lua
check_file run.sh
check_file Pirates/main.lua
check_file Pirates/gameplay.lua

# Lua must be decompiled source, not bytecode.
# The grep exits 1 in the GOOD case (not bytecode), so guard it from `set -e`.
if [ -f "$OUT/Pirates/main.lua" ]; then
    if head -c4 "$OUT/Pirates/main.lua" | grep -q $'\x1bLua' 2>/dev/null; then
        bad "Pirates/main.lua is still BYTECODE (decompile failed)"
    else
        ok "Lua decompiled to source"
    fi
fi

# Textures decoded.
NPNG=$(find "$OUT" -name '*.png' 2>/dev/null | wc -l | tr -d ' ')
[ "$NPNG" -gt 100 ] && ok "$NPNG PNG textures present" \
                    || bad "only $NPNG PNGs — PVR decode likely failed"

# No PVR should survive into the output (all should be decoded).
NPVR=$(find "$OUT" \( -name '*.pvr' -o -name '*.pv1' \) 2>/dev/null | wc -l | tr -d ' ')
[ "$NPVR" -eq 0 ] && ok "no undecoded PVR files left" \
                  || note "$NPVR PVR files remain (harmless; PNG is preferred at load)"

# Audio transcoded.
NOGG=$(find "$OUT" -name '*.ogg' 2>/dev/null | wc -l | tr -d ' ')
[ "$NOGG" -gt 50 ] && ok "$NOGG OGG audio files present" \
                   || bad "only $NOGG OGGs — audio transcode likely failed"

# Every Lua file in the output must parse (catches a bad patch application).
if command -v luac5.1 >/dev/null 2>&1; then
    badlua=0
    while IFS= read -r -d '' f; do
        luac5.1 -p "$f" >/dev/null 2>&1 || { echo "  [FAIL] syntax error: ${f#"$OUT"/}"; badlua=1; }
    done < <(find "$OUT" -name '*.lua' -print0)
    if [ "$badlua" -eq 0 ]; then ok "all Lua files parse"; else FAIL=$((FAIL+1)); fi
else
    note "luac5.1 not installed — skipping Lua syntax check (apt install lua5.1)"
fi
echo

# ---------------------------------------------------------------------------
echo "[7/7] Engine"
# ---------------------------------------------------------------------------
if [ "$WITH_ENGINE" -eq 1 ]; then
    note "building MOAI from source (this takes a while)…"
    if bash "$CLONE/scripts/build-moai.sh" "$SCRATCH/moai" >"$SCRATCH/moai-build.log" 2>&1; then
        ok "MOAI engine built"
        cp "$SCRATCH/moai" "$OUT/moai"
        chmod +x "$OUT/moai"
    else
        bad "MOAI build FAILED — last 20 lines:"
        tail -20 "$SCRATCH/moai-build.log" | sed 's/^/         /'
    fi
elif [ -x "$REPO/build/moai" ]; then
    note "reusing existing engine at build/moai (pass --with-engine to rebuild)"
    cp "$REPO/build/moai" "$OUT/moai"
    chmod +x "$OUT/moai"
    ok "engine staged into output"
else
    note "engine not built (pass --with-engine to build it here)"
fi
echo

# ---------------------------------------------------------------------------
echo "=============================================="
if [ "$FAIL" -eq 0 ]; then
    echo " RESULT: PASS  ($PASS checks)"
    echo
    echo " The repo is self-sufficient: a fresh clone plus this IPA rebuilds"
    echo " the game."
    if [ "$NPATCH" -eq 0 ]; then
        echo
        echo " NOTE: the patch series is empty, so the rebuilt game is an"
        echo "       unpatched decompile. Run scripts/make-patches.sh before"
        echo "       release."
    fi
    if [ -x "$OUT/moai" ] && [ "$PLAY" -eq 1 ]; then
        echo
        echo " Launching (--play)…"
        ( cd "$OUT" && ./run.sh )
    elif [ -x "$OUT/moai" ] && [ -t 0 ]; then
        # Only pause if we're on a terminal — never block CI.
        echo
        echo " To play the verified build before it is cleaned up, run in"
        echo " another terminal:   cd $OUT && ./run.sh"
        echo " (press Enter here to finish and delete the scratch dir)"
        read -r _
    fi
    echo "=============================================="
    exit 0
else
    echo " RESULT: FAIL  ($FAIL failed, $PASS passed)"
    echo
    echo " convert log: $LOG"
    echo " scratch dir will be removed on exit; re-run with the log open if"
    echo " you need to dig in."
    echo "=============================================="
    exit 1
fi

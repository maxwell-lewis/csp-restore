#!/usr/bin/env bash
#
# fetch-unluac.sh — download and pin the exact unluac build the patch series
# was generated against. Determinism of the decompile depends on this being
# the SAME jar for maintainer (patch generation) and user (patch application).
#
# We build from a pinned source commit rather than trusting a random binary,
# then verify its sha256 against the pin recorded here.
#
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="$REPO/converter/tools"
mkdir -p "$TOOLS"

# Pinned source: HansWessels/unluac (the fork used for this project's Lua 5.1
# decompiles). Pin to a specific commit so output is reproducible.
UNLUAC_REPO="https://github.com/HansWessels/unluac"
UNLUAC_COMMIT="__PIN_ME__"       # set to the exact commit SHA you built with
EXPECTED_JAR_SHA256="__PIN_ME__" # sha256 of the resulting unluac.jar

if [ "$UNLUAC_COMMIT" = "__PIN_ME__" ]; then
    cat <<'EOF'
This script is not yet pinned. To finalize it:
  1. git clone https://github.com/HansWessels/unluac /tmp/unluac
  2. cd /tmp/unluac && ./build.sh   (produces bin/unluac.jar)
  3. sha256sum bin/unluac.jar
  4. Record the commit SHA and jar sha256 in this script's PIN fields.
  5. Commit the resulting converter/tools/unluac.jar into the repo.

Pinning both the source commit and the output hash means every user's
decompile is byte-identical to the one the patches were generated against —
which is what makes the patch series apply cleanly.
EOF
    exit 1
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
git clone "$UNLUAC_REPO" "$TMP/unluac"
git -C "$TMP/unluac" checkout "$UNLUAC_COMMIT"
( cd "$TMP/unluac" && bash build.sh )
JAR="$(find "$TMP/unluac" -name 'unluac.jar' | head -1)"
got="$(sha256sum "$JAR" | awk '{print $1}')"
if [ "$got" != "$EXPECTED_JAR_SHA256" ]; then
    echo "unluac.jar sha256 mismatch:" >&2
    echo "  got:      $got" >&2
    echo "  expected: $EXPECTED_JAR_SHA256" >&2
    exit 1
fi
cp "$JAR" "$TOOLS/unluac.jar"
echo "unluac.jar pinned at $TOOLS/unluac.jar ($got)"

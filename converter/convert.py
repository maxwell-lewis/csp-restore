#!/usr/bin/env python3
"""
Crimson Steam Pirates — IPA → Linux port converter.

This program takes a user-supplied .ipa (the original 2011 iOS release,
downloadable from the Internet Archive) and rebuilds the playable Linux port
from it, on the user's own machine.

It ships NO copyrighted assets. Everything it produces is derived from the
user's own copy of the game. What THIS repository contributes is entirely
original work: the MOAI compatibility shim layer (boot.lua), mock modules,
and a set of unified diffs ("patches") that fix bugs and API drift in the
decompiled Lua. The patches contain only our changes — not Bungie/Harebrained
source.

Pipeline
--------
  1. Validate the IPA         (sha256 gate — refuse unknown builds)
  2. Unzip + locate app       (Payload/*.app)
  3. Decompile Lua bytecode   (unluac, pinned)
  4. Decode PVRTC textures    (-> PNG)
  5. Transcode audio          (AIF/IMA4 -> OGG via ffmpeg)
  6. Apply port overlay       (boot.lua, mocks, run.sh — our originals)
  7. Apply patch series       (our diffs, over the fresh decompile)
  8. Stage + verify           (into the output dir)

Usage
-----
  convert.py --ipa /path/to/CrimsonSteam.ipa --out ~/.local/share/csp
  convert.py --ipa game.ipa --out ./build --skip-checksum   (dev/testing)
"""

import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
OVERLAY = REPO / "port-overlay"
PATCHES = REPO / "patches"
TOOLS = HERE / "tools"

# --- Known-good IPA fingerprints -------------------------------------------
# The patch series is generated against ONE specific decompiler output, which
# in turn depends on the exact bytecode in one specific IPA build. Feeding a
# different build (e.g. the iPad "HD" SKU, a re-encoded upload, or a cracked
# dump) will produce a decompile the patches won't cleanly apply to. We gate
# on sha256 so the user gets a clear "unsupported build" message instead of a
# silently broken game.
#
# Populate this by running:  convert.py --fingerprint /path/to/your.ipa
# then paste the printed hash here with a human label.
SUPPORTED_IPAS = {
    "b2610d728e6af115e9e09ec52b636f72401658c2d308fbaa8551cfe43b970617":
        "Crimson Steam Pirates v1.2 (iPhone) — reference build",
}

# unluac is deterministic for a given jar + input. We pin the jar (checked in
# under converter/tools/) so every user's decompile is byte-identical to the
# one the patches were generated against.
UNLUAC_JAR = TOOLS / "unluac.jar"


class ConvertError(Exception):
    pass


def log(msg):
    print(f"[csp] {msg}", flush=True)


def sha256_file(path, chunk=1 << 20):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(chunk), b""):
            h.update(block)
    return h.hexdigest()


# --- Step 1: validate -------------------------------------------------------
def validate_ipa(ipa_path, skip_checksum=False):
    if not ipa_path.is_file():
        raise ConvertError(f"IPA not found: {ipa_path}")
    if not zipfile.is_zipfile(ipa_path):
        raise ConvertError(
            f"{ipa_path.name} is not a valid IPA (not a zip archive).\n"
            "Make sure you downloaded the .ipa file itself, not an .html "
            "landing page or a partial download."
        )
    digest = sha256_file(ipa_path)
    log(f"IPA sha256: {digest}")
    if skip_checksum:
        log("checksum gate SKIPPED (--skip-checksum); patches may not apply")
        return digest
    if not SUPPORTED_IPAS:
        raise ConvertError(
            "No supported-IPA fingerprints are configured in this build.\n"
            "The maintainer must run:  convert.py --fingerprint <ipa>\n"
            "and add the printed hash to SUPPORTED_IPAS. To bypass this during "
            "development, pass --skip-checksum."
        )
    if digest not in SUPPORTED_IPAS:
        supported = "\n".join(f"    {h[:16]}…  {label}"
                              for h, label in SUPPORTED_IPAS.items())
        raise ConvertError(
            f"This IPA is not a supported build.\n"
            f"  got:       {digest}\n"
            f"  supported:\n{supported}\n\n"
            "You likely have a different version (e.g. the iPad 'HD' edition) "
            "or a re-encoded upload. Download the exact build linked in the "
            "project README from the Internet Archive."
        )
    log(f"IPA recognised: {SUPPORTED_IPAS[digest]}")
    return digest


# --- Step 2: unzip + locate -------------------------------------------------
def extract_app(ipa_path, workdir):
    log("unzipping IPA…")
    with zipfile.ZipFile(ipa_path) as z:
        z.extractall(workdir)
    payload = workdir / "Payload"
    if not payload.is_dir():
        raise ConvertError("IPA has no Payload/ directory — not a valid iOS app archive.")
    apps = list(payload.glob("*.app"))
    if not apps:
        raise ConvertError("No .app bundle found inside Payload/.")
    app = apps[0]
    log(f"app bundle: {app.name}")
    # The game data lives under <app>/Pirates and <app>/Library
    if not (app / "Pirates").is_dir():
        raise ConvertError(
            f"{app.name} has no Pirates/ directory. This doesn't look like "
            "Crimson Steam Pirates."
        )
    return app


# --- Step 3: decompile Lua --------------------------------------------------
def is_lua_bytecode(path):
    try:
        with open(path, "rb") as f:
            return f.read(4) == b"\x1bLua"
    except OSError:
        return False


def decompile_lua(app_dir, staging):
    if not UNLUAC_JAR.is_file():
        raise ConvertError(
            f"unluac.jar not found at {UNLUAC_JAR}. It must be checked into "
            "the repo under converter/tools/."
        )
    if not shutil.which("java"):
        raise ConvertError("java not found on PATH (needed to run unluac).")

    lua_files = []
    for root, _dirs, files in os.walk(app_dir):
        for fn in files:
            if fn.endswith(".lua"):
                lua_files.append(Path(root) / fn)

    log(f"decompiling {len(lua_files)} Lua files…")
    done = 0
    for src in lua_files:
        rel = src.relative_to(app_dir)
        dst = staging / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        if is_lua_bytecode(src):
            with open(dst, "w", encoding="utf-8", errors="replace") as out:
                res = subprocess.run(
                    ["java", "-jar", str(UNLUAC_JAR), str(src)],
                    stdout=out, stderr=subprocess.PIPE
                )
            if res.returncode != 0:
                raise ConvertError(
                    f"unluac failed on {rel}:\n{res.stderr.decode(errors='replace')}"
                )
            # A zero-byte result means unluac ran but produced nothing (or the
            # shell redirect created the file before java failed). Treat this
            # as fatal — silently-empty decompiles are how you end up diffing
            # the whole game against nothing.
            if dst.stat().st_size == 0:
                raise ConvertError(
                    f"unluac produced an EMPTY file for {rel}. "
                    "The decompile is broken; refusing to continue."
                )
        else:
            # already plain-text Lua (some files ship as source)
            shutil.copy2(src, dst)
        done += 1
        if done % 100 == 0:
            log(f"  …{done}/{len(lua_files)}")
    log(f"decompiled {done} Lua files")


# --- Step 4: decode textures ------------------------------------------------
def decode_textures(app_dir, staging):
    from pvr_decode import decode_pvr_file  # local module

    pvrs = []
    for root, _dirs, files in os.walk(app_dir):
        for fn in files:
            if fn.endswith((".pvr", ".pv1")):
                pvrs.append(Path(root) / fn)
    log(f"decoding {len(pvrs)} PVR textures → PNG…")
    for i, src in enumerate(pvrs, 1):
        rel = src.relative_to(app_dir)
        # write PNG next to where the PVR would live, with .png extension
        dst = staging / rel.with_suffix(".png")
        dst.parent.mkdir(parents=True, exist_ok=True)
        try:
            decode_pvr_file(src, dst)
        except Exception as e:  # noqa: BLE001 — keep going, note failures
            log(f"  warn: could not decode {rel}: {e}")
        if i % 40 == 0:
            log(f"  …{i}/{len(pvrs)}")
    log("texture decode complete")


# --- Step 5: transcode audio ------------------------------------------------
def transcode_audio(app_dir, staging):
    if not shutil.which("ffmpeg"):
        raise ConvertError("ffmpeg not found on PATH (needed for audio).")
    aifs = []
    for root, _dirs, files in os.walk(app_dir):
        for fn in files:
            if fn.lower().endswith((".aif", ".aiff", ".caf")):
                aifs.append(Path(root) / fn)
    log(f"transcoding {len(aifs)} audio files → OGG…")
    for i, src in enumerate(aifs, 1):
        rel = src.relative_to(app_dir)
        dst = staging / rel.with_suffix(".ogg")
        dst.parent.mkdir(parents=True, exist_ok=True)
        res = subprocess.run(
            ["ffmpeg", "-y", "-loglevel", "error", "-i", str(src),
             "-ac", "1", "-ar", "22050", "-q:a", "4", str(dst)],
            stderr=subprocess.PIPE
        )
        if res.returncode != 0:
            log(f"  warn: ffmpeg failed on {rel}: "
                f"{res.stderr.decode(errors='replace')[:160]}")
        if i % 25 == 0:
            log(f"  …{i}/{len(aifs)}")
    log("audio transcode complete")


# --- Step 6: copy non-lua assets that ship as plain files -------------------
def copy_plain_assets(app_dir, staging):
    # PNG/TTF/OGG-already/music that ship uncompressed in the IPA.
    exts = (".png", ".ttf", ".otf", ".ogg", ".txt", ".fnt")
    log("copying plain asset files…")
    n = 0
    for root, _dirs, files in os.walk(app_dir):
        for fn in files:
            if fn.endswith(exts):
                src = Path(root) / fn
                rel = src.relative_to(app_dir)
                dst = staging / rel
                if dst.exists():
                    continue  # don't clobber a decoded-PVR PNG
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(src, dst)
                n += 1
    log(f"copied {n} plain asset files")


# --- Step 7: overlay + patches ----------------------------------------------
def apply_overlay(staging):
    log("applying port overlay (original shim files)…")
    for root, _dirs, files in os.walk(OVERLAY):
        for fn in files:
            src = Path(root) / fn
            rel = src.relative_to(OVERLAY)
            dst = staging / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)
    log("overlay applied")


def apply_patches(staging):
    if not shutil.which("patch"):
        raise ConvertError("`patch` utility not found on PATH.")
    series = PATCHES / "series"
    if not series.is_file():
        log("no patch series found — skipping (overlay-only build)")
        return
    names = [ln.strip() for ln in series.read_text().splitlines()
             if ln.strip() and not ln.startswith("#")]
    log(f"applying {len(names)} patches…")
    for name in names:
        pf = PATCHES / name
        if not pf.is_file():
            raise ConvertError(f"patch listed in series but missing: {name}")
        res = subprocess.run(
            ["patch", "-p1", "--forward", "--batch", "-i", str(pf)],
            cwd=staging, stdout=subprocess.PIPE, stderr=subprocess.STDOUT
        )
        if res.returncode != 0:
            raise ConvertError(
                f"patch {name} failed to apply:\n"
                f"{res.stdout.decode(errors='replace')}\n"
                "This usually means the decompiled source didn't match what "
                "the patch expects — likely a different IPA build or unluac "
                "version."
            )
    log("all patches applied")


# --- Step 8: stage + verify -------------------------------------------------
REQUIRED_AFTER = [
    "boot.lua",
    "Pirates/main.lua",
    "Pirates/gameplay.lua",
    "Pirates/img_iphone/splineDot.png",
]


def finalize(staging, out_dir):
    log(f"staging into {out_dir}…")
    if out_dir.exists():
        shutil.rmtree(out_dir)
    shutil.copytree(staging, out_dir)
    missing = [p for p in REQUIRED_AFTER if not (out_dir / p).exists()]
    if missing:
        raise ConvertError(
            "Conversion finished but these expected files are missing:\n  "
            + "\n  ".join(missing)
        )
    # make run.sh executable if present
    rs = out_dir / "run.sh"
    if rs.exists():
        rs.chmod(0o755)
    log("verification passed")


def convert(ipa_path, out_dir, skip_checksum=False, keep_work=False):
    ipa_path = Path(ipa_path).resolve()
    out_dir = Path(out_dir).resolve()
    validate_ipa(ipa_path, skip_checksum=skip_checksum)

    work = Path(tempfile.mkdtemp(prefix="csp-convert-"))
    try:
        extracted = work / "extracted"
        extracted.mkdir()
        app = extract_app(ipa_path, extracted)

        staging = work / "staging"
        staging.mkdir()

        decompile_lua(app, staging)
        decode_textures(app, staging)
        transcode_audio(app, staging)
        copy_plain_assets(app, staging)
        apply_overlay(staging)
        apply_patches(staging)
        finalize(staging, out_dir)

        log("")
        log("SUCCESS — Crimson Steam Pirates has been rebuilt.")
        log(f"  location: {out_dir}")
        log(f"  launch:   cd {out_dir} && ./run.sh")
    finally:
        if keep_work:
            log(f"work dir kept at {work}")
        else:
            shutil.rmtree(work, ignore_errors=True)


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Rebuild the Crimson Steam Pirates Linux port from your own IPA."
    )
    ap.add_argument("--ipa", help="path to the original .ipa file")
    ap.add_argument("--out", help="output directory for the playable game")
    ap.add_argument("--skip-checksum", action="store_true",
                    help="bypass the supported-build gate (dev/testing only)")
    ap.add_argument("--keep-work", action="store_true",
                    help="keep the temporary work directory for debugging")
    ap.add_argument("--fingerprint", metavar="IPA",
                    help="print the sha256 of an IPA and exit (for maintainers)")
    ap.add_argument("--decompile-only", action="store_true",
                    help="MAINTAINER: extract + decompile the IPA's Lua into "
                         "--out and stop. Used by scripts/make-patches.sh to "
                         "produce a baseline with the exact same code path the "
                         "end user runs, so diffs reflect only real changes.")
    args = ap.parse_args(argv)

    if args.fingerprint:
        p = Path(args.fingerprint)
        if not p.is_file():
            print(f"not found: {p}", file=sys.stderr)
            return 2
        print(sha256_file(p))
        return 0

    if not args.ipa or not args.out:
        ap.error("--ipa and --out are required (unless using --fingerprint)")

    if args.decompile_only:
        try:
            ipa_path = Path(args.ipa).resolve()
            out_dir = Path(args.out).resolve()
            validate_ipa(ipa_path, skip_checksum=True)
            work = Path(tempfile.mkdtemp(prefix="csp-decompile-"))
            try:
                extracted = work / "extracted"
                extracted.mkdir()
                app = extract_app(ipa_path, extracted)
                if out_dir.exists():
                    shutil.rmtree(out_dir)
                out_dir.mkdir(parents=True)
                decompile_lua(app, out_dir)
                log(f"baseline decompile written to {out_dir}")
            finally:
                shutil.rmtree(work, ignore_errors=True)
        except ConvertError as e:
            print(f"\n[csp] ERROR: {e}", file=sys.stderr)
            return 1
        return 0

    try:
        convert(args.ipa, args.out,
                skip_checksum=args.skip_checksum,
                keep_work=args.keep_work)
    except ConvertError as e:
        print(f"\n[csp] ERROR: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

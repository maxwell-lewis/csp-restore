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
  6. Install HD art pack      (optional — the Chrome Web Store release's
                               full-resolution art, from the user's own copy
                               of crimson.tar.gz or fetched from the Internet
                               Archive on request)
  7. Apply port overlay       (boot.lua, mocks, run.sh — our originals)
  8. Apply patch series       (our diffs, over the fresh decompile)
  9. Stage + verify           (into the output dir)

Usage
-----
  convert.py --ipa /path/to/CrimsonSteam.ipa --out ~/.local/share/csp
  convert.py --ipa game.ipa --out ./build --hd-pack ~/Downloads/crimson.tar.gz
  convert.py --ipa game.ipa --out ./build --download-hd-pack
  convert.py --ipa game.ipa --out ./build --skip-checksum   (dev/testing)
"""

import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
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

# --- HD art pack -------------------------------------------------------------
# The iPhone IPA only carries half-resolution UI art. The later desktop
# (Chrome Web Store) release shipped the iPad layout's full-resolution art:
# its img/ and particles/ directories are what boot.lua's HD mode loads.
# That release is NOT a complete game on its own (it has no single-player
# level scripts), so it is used purely as an art source on top of the IPA.
#
# Like the IPA, the archive is never redistributed here: the user supplies
# their own copy (--hd-pack) or asks the converter to fetch it from the
# Internet Archive (--download-hd-pack). It is checksum-gated the same way.
HD_PACK_URL = "https://archive.org/download/crimson.tar/crimson.tar.gz"
HD_PACK_PAGE = "https://archive.org/details/crimson.tar"
SUPPORTED_HD_PACKS = {
    "62bb6263f5013d3c28d9632594627ad121e766492f5c0e50708fef10e83c5acb":
        "Crimson Steam Pirates (Chrome Web Store) — crimson.tar.gz",
}
# archive subdirectory -> directory under Pirates/
HD_PACK_DIRS = {"img": "img", "particles": "particles"}

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


# --- Step 6b: HD art pack ----------------------------------------------------
def download_hd_pack(dest):
    log(f"downloading HD art pack from {HD_PACK_URL} …")
    req = urllib.request.Request(HD_PACK_URL,
                                 headers={"User-Agent": "csp-restore"})
    try:
        with urllib.request.urlopen(req) as resp, open(dest, "wb") as out:
            total = int(resp.headers.get("Content-Length") or 0)
            got, step = 0, 0
            for block in iter(lambda: resp.read(1 << 20), b""):
                out.write(block)
                got += len(block)
                if total and got * 10 // total > step:
                    step = got * 10 // total
                    log(f"  …{step * 10}%")
    except OSError as e:
        raise ConvertError(
            f"could not download the HD art pack: {e}\n"
            f"Download crimson.tar.gz yourself from {HD_PACK_PAGE} and pass "
            "it with --hd-pack."
        )
    return dest


def validate_hd_pack(pack_path, skip_checksum=False):
    if not pack_path.is_file():
        raise ConvertError(f"HD art pack not found: {pack_path}")
    if not tarfile.is_tarfile(pack_path):
        raise ConvertError(
            f"{pack_path.name} is not a tar archive. Make sure you downloaded "
            f"crimson.tar.gz itself from {HD_PACK_PAGE}."
        )
    digest = sha256_file(pack_path)
    log(f"HD pack sha256: {digest}")
    if skip_checksum:
        log("HD pack checksum gate SKIPPED (--skip-checksum)")
    elif digest not in SUPPORTED_HD_PACKS:
        raise ConvertError(
            f"This is not the supported HD art pack.\n"
            f"  got:      {digest}\n"
            f"  expected: {next(iter(SUPPORTED_HD_PACKS))}\n"
            f"Download crimson.tar.gz from {HD_PACK_PAGE}."
        )
    else:
        log(f"HD pack recognised: {SUPPORTED_HD_PACKS[digest]}")


def install_hd_pack(pack_path, staging):
    """Build Pirates/img and Pirates/particles from the Chrome release."""
    pirates = staging / "Pirates"
    log("installing HD art pack…")
    n = 0
    with tarfile.open(pack_path) as tar:
        for member in tar:
            if not member.isfile():
                continue
            parts = Path(member.name).parts
            # layout: crimson/<dir>/…  — take only the art directories, and
            # never trust a path from the archive beyond plain components.
            if len(parts) < 3 or parts[0] != "crimson" or parts[1] not in HD_PACK_DIRS:
                continue
            if any(p in ("", ".", "..") for p in parts):
                continue
            dst = pirates.joinpath(HD_PACK_DIRS[parts[1]], *parts[2:])
            dst.parent.mkdir(parents=True, exist_ok=True)
            with tar.extractfile(member) as src, open(dst, "wb") as out:
                shutil.copyfileobj(src, out)
            n += 1
    if n == 0:
        raise ConvertError("HD art pack contained no crimson/img files.")
    log(f"extracted {n} HD art files")

    # The pack's animation / particle scripts are Lua 5.1 bytecode built for
    # a 32-bit host; decompile them in place so the 64-bit engine can load them.
    if not shutil.which("java"):
        raise ConvertError("java not found on PATH (needed to run unluac).")
    d = 0
    for sub in HD_PACK_DIRS.values():
        for src in sorted((pirates / sub).rglob("*.lua")):
            if not is_lua_bytecode(src):
                continue
            res = subprocess.run(["java", "-jar", str(UNLUAC_JAR), str(src)],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if res.returncode != 0 or not res.stdout:
                raise ConvertError(
                    f"unluac failed on HD pack file {src.relative_to(pirates)}:\n"
                    f"{res.stderr.decode(errors='replace')}"
                )
            src.write_bytes(res.stdout)
            d += 1
    log(f"decompiled {d} HD pack Lua files")

    # A handful of textures the iPad layout references only ever shipped in
    # the iPhone build (splash screen, a few atlases and tutorial dialogs).
    # Fill those gaps from the IPA's art; ip_* files are iPhone-layout only.
    iphone = pirates / "img_iphone"
    hd = pirates / "img"
    g = 0
    if iphone.is_dir():
        for src in sorted(iphone.rglob("*")):
            if (not src.is_file() or src.name.startswith("ip_")
                    or src.suffix in (".pvr", ".pv1")):
                continue
            dst = hd / src.relative_to(iphone)
            if dst.exists():
                continue
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)
            g += 1
    log(f"filled {g} missing HD files from the iPhone art")


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


def convert(ipa_path, out_dir, skip_checksum=False, keep_work=False,
            hd_pack=None, download_hd=False):
    ipa_path = Path(ipa_path).resolve()
    out_dir = Path(out_dir).resolve()
    validate_ipa(ipa_path, skip_checksum=skip_checksum)
    if hd_pack:
        hd_pack = Path(hd_pack).expanduser().resolve()
        validate_hd_pack(hd_pack, skip_checksum=skip_checksum)

    work = Path(tempfile.mkdtemp(prefix="csp-convert-"))
    try:
        if download_hd and not hd_pack:
            hd_pack = download_hd_pack(work / "crimson.tar.gz")
            validate_hd_pack(hd_pack, skip_checksum=skip_checksum)

        extracted = work / "extracted"
        extracted.mkdir()
        app = extract_app(ipa_path, extracted)

        staging = work / "staging"
        staging.mkdir()

        decompile_lua(app, staging)
        decode_textures(app, staging)
        transcode_audio(app, staging)
        copy_plain_assets(app, staging)
        if hd_pack:
            install_hd_pack(hd_pack, staging)
        else:
            log("no HD art pack given — building the iPhone-resolution "
                "layout (see --hd-pack / --download-hd-pack)")
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
    ap.add_argument("--hd-pack", metavar="TARBALL",
                    help="path to crimson.tar.gz (the Chrome Web Store "
                         f"release, from {HD_PACK_PAGE}); enables the "
                         "full-resolution 1024x768 layout")
    ap.add_argument("--download-hd-pack", action="store_true",
                    help="fetch crimson.tar.gz from the Internet Archive "
                         "instead of supplying it with --hd-pack")
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
                keep_work=args.keep_work,
                hd_pack=args.hd_pack,
                download_hd=args.download_hd_pack)
    except ConvertError as e:
        print(f"\n[csp] ERROR: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

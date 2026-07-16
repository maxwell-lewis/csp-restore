# Maintainer setup

Steps to finalize this repo for release. End users don't do any of this — it's
for whoever prepares the repository.

## 1. Pin unluac

The decompile must be byte-reproducible, so pin the exact unluac build.

```bash
# build it
git clone https://github.com/HansWessels/unluac /tmp/unluac
cd /tmp/unluac && bash build.sh
sha256sum bin/unluac.jar          # record this
git -C /tmp/unluac rev-parse HEAD  # record this
```

- Copy `bin/unluac.jar` to `converter/tools/unluac.jar` and commit it.
- Fill the `UNLUAC_COMMIT` and `EXPECTED_JAR_SHA256` pins in
  `scripts/fetch-unluac.sh`.

> The `converter/tools/unluac.jar` in this repo was built from
> HansWessels/unluac. Verify its hash matches your pin before release.

## 2. Fingerprint the reference IPA

Pick the exact Internet Archive upload you'll support.

```bash
python3 converter/convert.py --fingerprint /path/to/CrimsonSteam.ipa
```

- Paste the printed sha256 into `SUPPORTED_IPAS` in `converter/convert.py`
  with a human label.
- Put the same hash and the Internet Archive URL in `README.md` and in
  `packaging/flatpak/csp-setup.py` (`ARCHIVE_URL`). Current source:
  https://archive.org/details/toasterifc-ipa-collection

## 3. Generate the patch series

You need your fully-working port tree (the one that plays start to finish).

```bash
scripts/make-patches.sh /path/to/CrimsonSteam.ipa /path/to/working-port
```

This:
- decompiles the IPA into a throwaway baseline (Bungie's source, never
  committed),
- diffs your working port against it,
- writes one `.patch` per modified file into `patches/` and lists them in
  `patches/series`,
- copies the pure-original files (`boot.lua`, `run.sh`, `Pirates/mock/*`) into
  `port-overlay/`.

Commit `patches/` and `port-overlay/`. **Never commit the baseline decompile
or any file under the game asset directories** — `.gitignore` already blocks
the obvious paths, but double-check `git status` before committing.

## 4. Verify a clean round-trip

The fastest way is the automated check:

```bash
scripts/verify.sh /path/to/CrimsonSteam.ipa --with-engine
```

It copies the repo to a scratch dir (simulating a fresh clone), checks host
dependencies, confirms no assets or decompiled source leaked into the repo,
runs the real end-user conversion against your IPA, and sanity-checks the
output (Lua actually decompiled, textures decoded, audio transcoded, every
Lua file parses). Exit code 0 means a stranger who clones the repo can
rebuild the game. Drop `--with-engine` to skip the slow MOAI build; add
`--play` to launch the result.

Manual equivalent:

On a fresh machine (or container) with only the repo + a downloaded IPA:

```bash
scripts/build-moai.sh
python3 converter/convert.py --ipa CrimsonSteam.ipa --out /tmp/csp-test
cp build/moai /tmp/csp-test/moai
cd /tmp/csp-test && ./run.sh
```

Confirm it plays. If a patch fails to apply, your working tree and the
baseline decompile diverged — regenerate patches (step 3) against the same
IPA you're shipping support for.

## 5. Build the Flatpak

```bash
cd packaging/flatpak
# provide wheels/ with texture2ddecoder + pillow wheels for offline build,
# or let the manifest pip-install them.
flatpak-builder --user --install --force-clean build-dir \
    io.github.csp_restore.CrimsonSteamPirates.yml
flatpak run io.github.csp_restore.CrimsonSteamPirates
```

First launch shows the setup window; point it at your IPA; it converts and
plays.

## What must never be committed

- The `.ipa` itself
- The baseline decompile (Bungie's source)
- Any game asset (textures, audio, music, fonts, level/ship/sailor scripts)
- The assembled game output

Only original work goes in the repo: shims, mocks, patches (diffs), build
tooling, packaging. See `docs/LEGAL.md`.

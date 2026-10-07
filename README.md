# csp-restore

**A build-your-own-copy converter for *Crimson Steam Pirates* on Linux.**

*Crimson Steam Pirates* was a turn-based naval-combat strategy game by Bungie /
Harebrained Schemes, released for iPhone in December 2011 and built on the
[MOAI SDK](https://github.com/moai/moai-dev). It was later delisted, and can no longer be purchased.
This project restores it as a native Linux game.

This repository contains no game assets. It ships only original work: a
MOAI compatibility shim layer, mock modules, a set of source patches, and the
tooling to rebuild the game. You supply your own copy of the original `.ipa`
(see [Getting the IPA](#getting-the-ipa)), and optionally the HD art pack
(see [HD art pack](#hd-art-pack)); the converter rebuilds the playable game
from them, entirely on your own machine.

This is the same model used by ScummVM, DXX-Rebirth, and other engine
reimplementations: **we provide the engine and the fixes; you bring the game
data.**

---

## What this does

Given the original iOS `.ipa`, the converter:

1. **Validates** the IPA against a known-good checksum (refuses unknown builds
   with a clear message rather than producing a broken game).
2. **Decompiles** the game's Lua 5.1 bytecode with a pinned `unluac`.
3. **Decodes** the PowerVR (PVRTC) textures to PNG.
4. **Transcodes** the iOS audio (AIF/IMA4) to OGG.
5. **Installs the HD art pack** (optional) — the full-resolution art from the
   later Chrome Web Store release, which switches the whole UI to the
   1024×768 layout.
6. **Applies the port overlay** — our original shim files (`boot.lua`, mocks).
7. **Applies the patch series** — our fixes for MOAI API drift, decompiler
   artifacts, Box2D version differences, and dozens of gameplay bugs, captured
   as unified diffs against the fresh decompile.
8. **Stages and verifies** a ready-to-run game directory.

The result plays start to finish — all three sagas, every chapter, with audio,
at desktop resolution.

---

## Quick start

### 1. Install dependencies

Debian / Ubuntu:

```bash
sudo apt install python3 python3-pip default-jre ffmpeg patch \
     build-essential cmake git \
     libsdl2-dev freeglut3-dev libgl1-mesa-dev libglu1-mesa-dev \
     libx11-dev libxext-dev libxrandr-dev libxxf86vm-dev \
     libxcursor-dev libxinerama-dev zlib1g-dev libfreetype-dev libpng-dev
# Debian/Ubuntu's Python is externally managed (PEP 668) — use a venv:
python3 -m venv ~/.venvs/csp
~/.venvs/csp/bin/pip install texture2ddecoder pillow
source ~/.venvs/csp/bin/activate   # run the converter from this shell
```

Arch:

```bash
sudo pacman -S python python-pip jre-openjdk ffmpeg patch \
     base-devel cmake git sdl2 freeglut mesa glu libx11 libxext \
     libxrandr libxxf86vm libxcursor libxinerama zlib freetype libpng
# Arch's Python is externally managed (PEP 668) — use a venv:
python -m venv ~/.venvs/csp
~/.venvs/csp/bin/pip install texture2ddecoder pillow
source ~/.venvs/csp/bin/activate   # run the converter from this shell
```

Fedora:

```bash
sudo dnf install python3 python3-pip java-latest-openjdk-headless ffmpeg \
     patch gcc-c++ cmake git SDL2-devel freeglut-devel mesa-libGL-devel \
     mesa-libGLU-devel libX11-devel libXext-devel libXrandr-devel \
     libXxf86vm-devel libXcursor-devel libXinerama-devel zlib-devel freetype-devel libpng-devel
# Fedora's Python is externally managed (PEP 668) — use a venv:
python3 -m venv ~/.venvs/csp
~/.venvs/csp/bin/pip install texture2ddecoder pillow
source ~/.venvs/csp/bin/activate   # run the converter from this shell
```

### 2. Build the MOAI engine (one time)

```bash
scripts/build-moai.sh
```

This clones the open-source MOAI SDK, applies the Linux-compat patches, and
produces `build/moai`. (No game data involved — this is pure open-source.)

### 3. Get the IPA

See [Getting the IPA](#getting-the-ipa) below. Download it to, say,
`~/Downloads/CrimsonSteam.ipa`.

### 4. Convert

```bash
python3 converter/convert.py \
    --ipa ~/Downloads/CrimsonSteam.ipa \
    --download-hd-pack \
    --out ~/.local/share/crimson-steam-pirates
```

`--download-hd-pack` fetches the [HD art pack](#hd-art-pack) (~100 MB) from
the Internet Archive. If you already downloaded it, use
`--hd-pack ~/Downloads/crimson.tar.gz` instead. Leave both off to build the
original iPhone-resolution game.

### 5. Play

```bash
cp build/moai ~/.local/share/crimson-steam-pirates/moai
cd ~/.local/share/crimson-steam-pirates
./run.sh
```

(Or use the [Flatpak](packaging/flatpak/), which bundles the engine and wraps
all of the above into a first-run setup screen.)

---

## Getting the IPA

The original app is archived at the Internet Archive:

> **https://archive.org/details/toasterifc-ipa-collection**
>
> Direct file: [`Crimson Steam Pirates-v1.2.ipa`](https://archive.org/download/toasterifc-ipa-collection/Crimson%20Steam%20Pirates-v1.2.ipa)
>
> Expected file: `Crimson Steam Pirates-v1.2.ipa` (v1.2, iPhone, ~89 MB)
> sha256: `b2610d728e6af115e9e09ec52b636f72401658c2d308fbaa8551cfe43b970617`

Download the `.ipa` and point the converter at it. The converter checks the
checksum and will tell you if you have a different build (for example the iPad
"HD" edition, which uses different assets and is not supported).

> **Note.** The converter supports one specific build. If your download's
> checksum doesn't match, you likely have a different upload or edition —
> grab the exact file linked above.

---

## HD art pack

The iPhone release only carries half-resolution UI art (480×320). The game was
later released on the Chrome Web Store with the full-resolution iPad layout
(1024×768). That release is archived at the Internet Archive:

> **https://archive.org/details/crimson.tar**
>
> Direct file: [`crimson.tar.gz`](https://archive.org/download/crimson.tar/crimson.tar.gz) (~100 MB)
> sha256: `62bb6263f5013d3c28d9632594627ad121e766492f5c0e50708fef10e83c5acb`

It is not a complete game on its own — it has no single-player missions — so
the converter uses it purely as an art source on top of the IPA: it takes the
archive's `img/` and `particles/` directories, decompiles their animation
scripts, and installs them as `Pirates/img/` and `Pirates/particles/`. When
those are present the game runs the HD layout: main menu, loading screens,
briefings, and HUD all use the full-resolution art.

Pass it with `--hd-pack /path/to/crimson.tar.gz`, or let the converter fetch
it with `--download-hd-pack`. Like the IPA it is checksum-gated and never
redistributed by this repository.

To run an HD build in the original iPhone layout: `CSP_UI=iphone ./run.sh`.

---

## Why it works this way

The game's copyright is held by its original creators (Harebrained Schemes was
acquired by Paradox Interactive; the IP traces back through Bungie). We can't
distribute their assets or their decompiled source. What we *can* distribute is
our own work:

- **`port-overlay/`** — files that are 100% ours (the shim layer, mocks,
  launcher). These contain no game code.
- **`patches/`** — unified diffs. A diff contains only the *changes* we made,
  not the underlying source. Applied to *your* fresh decompile of *your* IPA,
  they reproduce the fixed game — on your machine, from your data.

Nothing copyrighted ever lives in this repo or the Flatpak. See
[docs/LEGAL.md](docs/LEGAL.md).

---

## Repository layout

```
converter/          the conversion pipeline (Python)
  convert.py          main driver: IPA -> playable game
  pvr_decode.py       PVRTC -> PNG decoder
  tools/unluac.jar    pinned Lua 5.1 decompiler
port-overlay/       original shim files, copied in verbatim
  boot.lua            MOAI 1.5 compatibility shim layer (~940 lines)
  run.sh              launcher
  Pirates/mock/       stubs for iOS-only modules (Facebook, Game Center)
patches/            unified diffs over the fresh decompile (+ series file)
scripts/
  build-moai.sh       build the MOAI engine from source
  fetch-unluac.sh     download/pin the exact unluac build
  make-patches.sh     MAINTAINER: regenerate patches from a working port
  verify.sh           MAINTAINER: clean-room round-trip check before release
packaging/flatpak/  Flatpak manifest + first-run setup UI
docs/               LEGAL.md, PORTING-NOTES.md
```

---

## What was fixed

The port required bridging ~3 years of MOAI API drift plus fixing bugs the
Lua decompiler introduced and behavior differences in bundled libraries.
Highlights (full detail in [docs/PORTING-NOTES.md](docs/PORTING-NOTES.md)):

- **API drift**: `getTime`→`getDeviceTime`, `setLength`→`setSpan`,
  `crypto.evp`→`crypto.digest`, `MOAITransform`→`MOAICamera2D` for cameras,
  vertex-format signatures, particle-emitter class split, and more.
- **Decompiler artifacts**: three separate `while true do … break` loops that
  the decompiler emitted where the original had real `while` conditions —
  including one in the trigger engine's OR-condition handling that broke the
  entire arctic chapter.
- **Multi-return loss**: the `dofile` shim was dropping second return values,
  silently nulling the particle list and the multiplayer level list.
- **Box2D version drift**: ships moved at exactly half speed because the
  thrust constant was tuned for Box2D 2.1 and the build uses 2.3; recalibrated.
- **Audio**: rebuilt the engine against system SDL2 so sound plays through
  ALSA/PulseAudio (the bundled static SDL2 only had a dummy driver).
- **PVRTC textures**: decoded to PNG since desktop GL can't sample PVRTC.

---
## Graphics

The IPA only contains iPhone-resolution art. Build with the
[HD art pack](#hd-art-pack) to get the full-resolution 1024×768 layout from
the Chrome Web Store release.
There is a visual bug with the ship trajectory display that
makes it appeared offset from the ship, this however does not affect gameplay.

## Legal

For personal preservation and research. See [docs/LEGAL.md](docs/LEGAL.md).
This project distributes no copyrighted material; you supply your own copy of
a game you obtained. That said, the underlying work is still under copyright —
this tooling doesn't change that, it just keeps the copyrighted parts on your
machine and off the internet.

## License

The original code in this repository (converter, shims, patches, scripts,
packaging) is released under the MIT License — see [LICENSE](LICENSE). This
license covers **only** this repository's original contributions, not the
game, not the MOAI SDK (CPAL), and not `unluac`.

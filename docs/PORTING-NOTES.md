# Porting notes

A record of what it took to get *Crimson Steam Pirates* (iOS, Dec 2011, MOAI
SDK) running on Linux under MOAI 1.5-stable. Useful if you're porting another
MOAI-era iOS game, or just curious what the patch series is doing.

## The shape of the problem

The game was compiled against a December 2011 MOAI revision. The newest
buildable open-source MOAI is `1.5-stable` (~2014). Between those two points
the engine's Lua-facing API drifted: methods renamed, classes split, argument
signatures changed, some iOS-only features removed. On top of that:

- The game shipped as Lua **bytecode**, so it had to be decompiled — and the
  decompiler introduced its own artifacts.
- Textures are **PVRTC** (PowerVR hardware format) which desktop GL can't
  sample.
- Audio is iOS **AIF/IMA4**.
- The engine's bundled static SDL2 only had a **dummy audio driver**.
- Facebook, Game Center, in-app purchase, and Bungie's "aero" servers are all
  gone.

## Engine build (`scripts/build-moai.sh`)

Ten source patches to build MOAI on modern Linux:

1. `src/zl-util/ZLAdapterInfo_posix.cpp` — guard `#include <sys/sysctl.h>`
   behind `#if __APPLE__` (glibc dropped the header at 2.30).
2. `cmake/host-glut/CMakeLists.txt` — add the X11/GL link libs
   (`Xext Xrandr Xxf86vm Xcursor Xinerama GL GLU glut dl pthread`).
3. `cmake/third-party/untz/CMakeLists.txt` — build the Untz audio layer
   against **system SDL2** (`pkg_check_modules(SYSTEM_SDL2 REQUIRED sdl2)`)
   instead of the bundled static SDL2. This is the fix that makes sound
   actually play through ALSA/PulseAudio.
4. `cmake/third-party/png/CMakeLists.txt` + `cmake/third-party/zlib/CMakeLists.txt` —
   swap the bundled libpng 1.4.0 / zlib 1.2.3 (2010/2005, uncompilable on a
   modern toolchain) for the **system** libraries; INTERFACE wrappers keep the
   `png`/`zlib` target names so downstream links still resolve.
5. `cmake/third-party/freetype/CMakeLists.txt` — swap bundled FreeType 2.4.4
   for the **system** library (the font reader only uses the stable core API).
6. `cmake/third-party/luaext/*/CMakeLists.txt` — fix the `add_dependencies`
   target-name typo (`lualib-static` vs the real `liblua-static`) that is a
   hard error at generate time under CMake 4.x.
7. `crypto/ui/ui_openssl.c` + `crypto/des/read_pwd.c` — select **TERMIOS**
   instead of TERMIO (`<termio.h>` removed in glibc 2.42+); only the
   never-called interactive password UI is affected.
8. `cmake/third-party/sdl2/CMakeLists.txt` — do **not** build the vendored
   SDL 2.0.0 (its GL renderer conflicts with modern `glext.h`); replace it
   with an INTERFACE wrapper around system SDL2.
9. `cmake/third-party/CMakeLists.txt` + `cmake/third-party/luaext/CMakeLists.txt` —
   gate the third-party curl and luacurl subdirectories behind `MOAI_CURL`
   (off in this build) so the dead 2010-era code never configures.
10. `3rdparty/luasql-2.2.0/src/ls_sqlite3.c` — fix `opts_settimeout` passing
    the Lua wrapper struct to `sqlite3_busy_timeout` instead of the raw
    `sqlite3*` handle (hard error on GCC 14+).

## Shim layer (`port-overlay/boot.lua`)

~940 lines of pure-Lua compatibility shims installed before the game's
`main.lua` runs. Highlights:

| 2011 API                       | 1.5 situation         | Shim |
|--------------------------------|-----------------------|------|
| `MOAISim.getTime`              | renamed               | alias to `getDeviceTime` |
| `MOAISim.getSimTime`           | renamed               | alias to `getElapsedTime` |
| `MOAISim.getDeviceIDString`    | removed (iOS UDID)    | returns a fixed string |
| `MOAISim.*NativeSound*`        | iOS-only              | route through MOAIUntzSound; honor volume + loop count |
| `MOAITransform.new()` camera   | strict typing         | swap to `MOAICamera2D.new()` |
| `MOAIVertexFormat:declare*`    | new arg signature     | auto-index wrapper |
| `MOAISimpleShader`             | removed               | wrap `MOAIColor`; install ATTR links |
| `MOAITimer` LOOP semantics     | also fires END_SPAN   | register on both |
| `MOAIParticleEmitter`          | class split           | alias to `MOAIParticleTimedEmitter` |
| `MOAIBox2DWorld.decomposePolygon` | removed            | Lua ear-clipping fallback |
| `crypto.evp`                   | renamed `crypto.digest` | module alias |
| `string.pack`/`unpack`         | 5.3-only              | pure-Lua polyfill |
| `MOAIHttpTask`                 | not built             | stub returns empty success |
| `dofile` multi-return          | shim ate 2nd value    | capture-all-returns closure |

The `dofile` multi-return fix matters more than it sounds: `fxlist.lua`
returns `(fxList, particleList)` and `levelList.lua` returns
`(levelList, multiLevelList)`. Dropping the second value silently nulled the
particle list (crash on first ship death) and the multiplayer level list.

## Decompiler artifacts (patched game source)

The Lua decompiler emitted `while true do … break` in three places where the
original clearly had a real `while <cond> do`:

1. `srHandler.lua` firing loop
2. `srHandler.lua` cruising-sound loop
3. `triggerManager.lua` OR-condition grouping — this one collected only the
   single condition immediately before an `OR` separator into the first group,
   dropping the rest of the AND-chain. It broke every trigger in the arctic
   chapter (all of chapter 3 uses OR conditions; sagas 1–2 use none), causing
   instant turn-1 defeats. Also a latent infinite-loop if `OR` were the first
   condition.

Fingerprint for future decompiles: **`while true do … break` where a real
loop condition was expected** is a decompiler tell. Grep for it proactively.

## Gameplay / library fixes

- **Box2D thrust** (`collision.lua`): ships moved at exactly half speed. The
  turn-start thrust used a `5.5` multiplier tuned for Box2D 2.1; the build
  links Box2D 2.3, whose damping integration differs. Measured ratio was a
  flat `0.49` across all ships → doubled the multiplier to `11.0`; measured
  `0.99` after. Exposed as `DESKTOP_THRUST_MULTIPLIER`.
- **`getWorldDir` staleness** (`shipManager.lua`): 1.5 defers the
  world-matrix update to render time, so the per-frame path projection read a
  one-frame-stale heading and the movement dotted-line was offset. Use the
  already-computed direction unit vector instead.
- **`panic` global** (`srHandler.lua`): a never-reset global that, once set,
  spammed `PANIC!!!` forever across missions. Localized per-turn.
- **`voyageend.lua` state-aware init**: the end-of-mission scene's idempotency
  guard blocked re-init when the win/lose state changed after the first init,
  leaving the lose menu unpopulated and crashing on defeat. Track the
  initialized state and re-run on change; guard the input handlers.
- **`removeProp`/`insertProp` tolerance**: some cleanup paths pass a
  transform/camera where a prop is expected; 1.5 type-checks strictly. Wrap in
  pcall so cleanup doesn't cascade into orphaned looping animations/audio.

## Assets

- **PVRTC → PNG** (`converter/pvr_decode.py`): CPU-decode the PowerVR textures
  and re-emit PNG; the loader prefers PNG.
- **AIF → OGG** (ffmpeg, mono 22050 q4): the native-sound shim swaps the file
  extension at play time.
- **Resolution**: logical 480×320 iPhone space, upscaled 3× to a 1440×960
  window; text scaled 1.4× for legibility. Sub-viewport `setSize` calls
  converted from display units to window pixels.
- **HD art pack** (optional, `--hd-pack` / `--download-hd-pack`): the Chrome
  Web Store release shipped the iPad layout's full-resolution art but no
  single-player level scripts, so it is used as an art source only. Its
  `img/` and `particles/` become `Pirates/img/` and `Pirates/particles/`
  (bytecode animation scripts decompiled; textures that only shipped in the
  iPhone build filled in from `img_iphone/`). `boot.lua` then reports a
  1024×768 screen so the game's own `IPAD_UI` branches run, upscaled 1.40625×
  to 1440×1080. `CSP_UI=iphone` forces the old layout.
- **Font sizes**: 2011 MOAI's `font:getScale()` returned pixels
  (points × dpi / 72); the shim reports that in HD mode so font-sized text
  matches the art.
- **`MOAITextBox:setStringColor`**: removed in 1.5; shimmed with inline
  `<c:…>` style spans (options menu On/Off labels).

## IAP / online

Chapter unlocks were gated behind App Store purchases that can no longer
happen (servers gone, app delisted). The store module is stubbed so all
chapters are available. Facebook/Game Center/aero calls are mocked to no-op
success.

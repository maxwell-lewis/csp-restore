# Legal notes

**This is not legal advice.** It's a plain description of how this project is
structured and why. If you plan to do anything beyond running the game
privately for yourself, talk to an actual IP attorney.

## What this repository contains

- Original code: the MOAI compatibility shim layer, mock modules, the
  conversion pipeline, build scripts, and packaging.
- Unified diffs ("patches") that express **only the changes** we made to the
  decompiled game source — not the source itself.

## What it deliberately does **not** contain

- No game textures, audio, music, fonts, level scripts, story content, or any
  other asset.
- No decompiled game source. The patches are diffs; a diff records the
  before/after of the lines that changed, not the whole file. The complete
  game source only ever exists transiently, on the user's machine, produced
  from the user's own IPA during conversion.

## Why it's structured this way

*Crimson Steam Pirates* is copyrighted by its creators. Harebrained Schemes
(the developer) was acquired by Paradox Interactive; the IP history runs back
through Bungie. The game was delisted from the App Store and can no longer be
purchased.

"Delisted" and "unpurchasable" do **not** mean "public domain." The game is
still fully under copyright. Distributing its assets or its source, even for
a dead, unbuyable game, would infringe that copyright.

This project follows the established engine-reimplementation model (ScummVM,
DXX-Rebirth, OpenRCT2's early asset handling, etc.): the tooling is
distributed; the copyrighted data is supplied by the user from a copy they
obtained. This keeps the copyrighted material off the internet and on the
user's own machine.

## What that does and doesn't do for you

- It removes this project from the business of distributing copyrighted
  assets — the part that actually draws enforcement (takedowns, etc.).
- It does not grant you a license to the game. Running the converter
  produces a derivative work on your machine. For private, personal use the
  practical risk is negligible, but "negligible practical risk" is not the
  same as "licensed." 
- If you redistribute the *output* of the converter (the assembled game), or
  bundle the assets into a package and share it, you are back to distributing
  copyrighted material and this project's structure no longer protects you.

## Third-party licenses

- **MOAI SDK** — CPAL 1.0. The engine binary produced by `build-moai.sh` is
  derived from MOAI source and carries MOAI's license. Attribution per the
  "Made With Moai" requirements applies.
- **unluac** — see its own repository for licensing; used here as a build tool.
- The MOAI binary statically links several permissively-licensed libraries
  (Box2D, Chipmunk, FreeType, libpng, libjpeg, libogg, libvorbis, SQLite,
  TinyXML, Lua, Untz, etc.); their licenses are in the MOAI source tree.

## If a rights holder objects

If Paradox / the rights holders ask this project to stop, the intended
response is to comply. The point here is preservation and personal use, not
a fight over IP.

#!/usr/bin/env bash
#
# build-moai.sh — build the MOAI 1.5 host binary from source for Linux.
#
# The MOAI SDK is open source (CPAL). The game runs on top of it. This script
# clones the pinned MOAI source, applies the small Linux-compatibility patches
# this project needs, and builds a `moai` host binary linked against the
# system SDL2 (so audio works through ALSA/PulseAudio).
#
# The resulting binary is 100% open-source-derived — no Bungie code. It is
# safe to ship in the Flatpak/repo.
#
# Requires: git, cmake, a C++ toolchain, and dev headers for:
#   SDL2, OpenGL/GLU, GLUT (freeglut), X11 (Xext/Xrandr/Xxf86vm/Xcursor/
#   Xinerama), zlib. On Debian/Ubuntu:
#     sudo apt install build-essential cmake git libsdl2-dev freeglut3-dev \
#          libgl1-mesa-dev libglu1-mesa-dev libx11-dev libxext-dev \
#          libxrandr-dev libxxf86vm-dev libxcursor-dev libxinerama-dev zlib1g-dev
#
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$REPO/build/moai}"

MOAI_REPO="https://github.com/moai/moai-dev.git"
MOAI_BRANCH="1.5-stable"

WORK="$(mktemp -d)"
cleanup() {
    status=$?
    if [ "$status" -eq 0 ]; then
        rm -rf "$WORK"
    else
        echo "" >&2
        echo "Build FAILED — source/build tree kept for debugging at:" >&2
        echo "    $WORK" >&2
        echo "You can fix and re-run 'make' inside $WORK/moai-dev/cmake/build" >&2
        echo "without re-cloning. Delete the directory when done." >&2
    fi
}
trap cleanup EXIT
SRC="$WORK/moai-dev"

echo "== Cloning MOAI ($MOAI_BRANCH) =="
git clone --depth 1 -b "$MOAI_BRANCH" --filter=blob:none "$MOAI_REPO" "$SRC"

echo "== Applying Linux-compat patches =="

# Patch 1: guard <sys/sysctl.h> (removed in glibc 2.30+) to __APPLE__ only.
ADAPTER="$SRC/src/zl-util/ZLAdapterInfo_posix.cpp"
if [ -f "$ADAPTER" ]; then
    # Wrap the sysctl include in an __APPLE__ guard if not already guarded.
    python3 - "$ADAPTER" <<'PY'
import sys, re
p = sys.argv[1]
s = open(p).read()
if "sys/sysctl.h" in s and "__APPLE__" not in s.split("sys/sysctl.h")[0][-40:]:
    s = s.replace(
        "#include <sys/sysctl.h>",
        "#if __APPLE__\n#include <sys/sysctl.h>\n#endif",
    )
    open(p, "w").write(s)
    print("  patched ZLAdapterInfo_posix.cpp")
else:
    print("  ZLAdapterInfo_posix.cpp: already guarded or not present")
PY
fi

# Patch 2: host-glut link libs — ensure X11/GL libs are linked on Linux.
GLUT_CMAKE="$SRC/cmake/host-glut/CMakeLists.txt"
if [ -f "$GLUT_CMAKE" ] && ! grep -q "Xrandr" "$GLUT_CMAKE"; then
    cat >> "$GLUT_CMAKE" <<'CMAKE'

# --- Linux desktop link libraries (added by csp-restore build-moai.sh) ---
if ( UNIX AND NOT APPLE )
  target_link_libraries ( moai
    GL GLU glut
    X11 Xext Xrandr Xxf86vm Xcursor Xinerama
    dl pthread )
endif ()
CMAKE
    echo "  patched host-glut/CMakeLists.txt"
fi

# Patch 3: build untz (audio) against system SDL2 instead of the bundled
# static SDL2 (which only had a dummy audio driver). This is what makes
# sound actually play.
UNTZ_CMAKE="$SRC/cmake/third-party/untz/CMakeLists.txt"
if [ -f "$UNTZ_CMAKE" ] && ! grep -q "SYSTEM_SDL2" "$UNTZ_CMAKE"; then
    python3 - "$UNTZ_CMAKE" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
# Prepend a pkg-config lookup for system SDL2 and swap the static target.
inject = (
    "find_package ( PkgConfig REQUIRED )\n"
    "pkg_check_modules ( SYSTEM_SDL2 REQUIRED sdl2 )\n\n"
)
if "SYSTEM_SDL2" not in s:
    s = inject + s
    # Link system sdl2 into untz; drop the bundled SDL2-static dependency.
    s = s.replace("SDL2-static", "${SYSTEM_SDL2_LIBRARIES}")
    s += (
        "\n# csp-restore: use system SDL2 for real ALSA/Pulse audio\n"
        "target_include_directories ( untz PUBLIC ${SYSTEM_SDL2_INCLUDE_DIRS} )\n"
        "target_link_libraries ( untz ${SYSTEM_SDL2_LIBRARIES} )\n"
    )
    open(p, "w").write(s)
    print("  patched untz/CMakeLists.txt (system SDL2)")
else:
    print("  untz/CMakeLists.txt: already patched")
PY
fi

# Patch 4: MOAI bundles libpng 1.4.0 (2010) and zlib 1.2.3 (2005). Neither
# compiles on a modern toolchain — libpng 1.4 collides with today's
# <setjmp.h> and uses png types GCC 16 rejects. Rather than fight fossil C,
# swap both to the system libraries (Arch/Debian ship current, maintained
# versions). We keep the CMake target NAMES 'png' and 'zlib' so every
# downstream target_link_libraries(... png/zlib) still resolves — we just
# make those targets be INTERFACE wrappers around the system libs.
PNG_CMAKE="$SRC/cmake/third-party/png/CMakeLists.txt"
if [ -f "$PNG_CMAKE" ]; then
    cat > "$PNG_CMAKE" <<'CMAKE'
# csp-restore: use system libpng instead of bundled lpng140 (won't build on
# modern toolchains).
cmake_minimum_required ( VERSION 3.5 )
project ( png )
find_package ( PkgConfig REQUIRED )
pkg_check_modules ( SYS_PNG REQUIRED libpng )
add_library ( png INTERFACE )
target_include_directories ( png INTERFACE ${SYS_PNG_INCLUDE_DIRS} )
target_link_libraries ( png INTERFACE ${SYS_PNG_LIBRARIES} )
CMAKE
    echo "  patched third-party/png (system libpng)"
fi

ZLIB_CMAKE="$SRC/cmake/third-party/zlib/CMakeLists.txt"
if [ -f "$ZLIB_CMAKE" ]; then
    cat > "$ZLIB_CMAKE" <<'CMAKE'
# csp-restore: use system zlib instead of bundled zlib-1.2.3.
cmake_minimum_required ( VERSION 3.5 )
project ( zlib )
find_package ( ZLIB REQUIRED )
add_library ( zlib INTERFACE )
target_include_directories ( zlib INTERFACE ${ZLIB_INCLUDE_DIRS} )
target_link_libraries ( zlib INTERFACE ${ZLIB_LIBRARIES} )
CMAKE
    echo "  patched third-party/zlib (system zlib)"
fi

# Patch 5: same story for freetype. MOAI bundles FreeType 2.4.4 (2010); its
# internal C predates modern toolchain strictness. MOAI's font reader
# (MOAIFreeTypeFontReader) uses only the core, decades-stable FT2 public API
# (FT_Init_FreeType / FT_New_Face / FT_Load_Glyph / FT_Outline_Render with
# FT_RASTER_FLAG_DIRECT — all still present in current FreeType), so linking
# the system library is a clean swap.
FT_CMAKE="$SRC/cmake/third-party/freetype/CMakeLists.txt"
if [ -f "$FT_CMAKE" ]; then
    cat > "$FT_CMAKE" <<'CMAKE'
# csp-restore: use system freetype instead of bundled freetype-2.4.4.
cmake_minimum_required ( VERSION 3.5 )
project ( freetype )
find_package ( PkgConfig REQUIRED )
pkg_check_modules ( SYS_FT REQUIRED freetype2 )
add_library ( freetype INTERFACE )
target_include_directories ( freetype INTERFACE ${SYS_FT_INCLUDE_DIRS} )
# NOTE: must use _LINK_LIBRARIES (absolute paths). SYS_FT_LIBRARIES is the
# bare name 'freetype', which CMake would resolve to this very target (a
# self-reference that silently drops -lfreetype from the final link).
target_link_libraries ( freetype INTERFACE ${SYS_FT_LINK_LIBRARIES} )
# moai-sim's CMakeLists does:
#   get_target_property ( FREETYPE_INCLUDES freetype INCLUDE_DIRECTORIES )
# which on an INTERFACE library would return NOTFOUND. Populate the plain
# property too so that lookup keeps working.
set_target_properties ( freetype PROPERTIES
    INCLUDE_DIRECTORIES "${SYS_FT_INCLUDE_DIRS}" )
CMAKE
    echo "  patched third-party/freetype (system freetype)"
fi

# Belt-and-suspenders for the same get_target_property call: if it still
# comes back NOTFOUND, neutralize it so a literal 'FREETYPE_INCLUDES-NOTFOUND'
# doesn't get injected into moai-sim's include path.
SIM_CMAKE="$SRC/cmake/moai-sim/CMakeLists.txt"
if [ -f "$SIM_CMAKE" ] && ! grep -q "csp-restore notfound guard" "$SIM_CMAKE"; then
    python3 - "$SIM_CMAKE" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
anchor = "get_target_property ( FREETYPE_INCLUDES freetype INCLUDE_DIRECTORIES )"
guard = (
    anchor + "\n"
    "# csp-restore notfound guard\n"
    "if ( NOT FREETYPE_INCLUDES )\n"
    "  set ( FREETYPE_INCLUDES \"\" )\n"
    "endif ()\n"
)
if anchor in s:
    s = s.replace(anchor, guard, 1)
    open(p, "w").write(s)
    print("  patched moai-sim (FREETYPE_INCLUDES guard)")
else:
    print("  moai-sim: anchor not found (skipping guard)")
PY
fi

# Patch 6: MOAI's five luaext modules declare
#     add_dependencies ( <module> lualib-static )
# but the lua target is actually named 'liblua-static' — a typo in upstream
# MOAI. Old CMake treated a dependency on a non-existent target as a warning
# (policy CMP0046 OLD, implied by the 2.8.x minimums). Because we configure
# with -DCMAKE_POLICY_VERSION_MINIMUM=3.5 for CMake 4.x, CMP0046 flips to NEW
# and the typo becomes a hard "dependency target does not exist" error at
# generate time. Fix the name. (The dependency is redundant anyway — each
# module already does target_link_libraries(... ${LUA_LIB}) — but correcting
# it is the smallest change.)
LUAEXT_FIXED=0
for f in "$SRC"/cmake/third-party/luaext/*/CMakeLists.txt; do
    if grep -q "lualib-static" "$f"; then
        sed -i 's/lualib-static/liblua-static/g' "$f"
        LUAEXT_FIXED=$((LUAEXT_FIXED+1))
    fi
done
[ "$LUAEXT_FIXED" -gt 0 ] && echo "  patched luaext add_dependencies target name ($LUAEXT_FIXED files)"

# Patch 7: bundled OpenSSL 1.0.0m force-selects the legacy TERMIO terminal
# interface on Linux, which needs <termio.h> — a header glibc 2.42+ (Arch,
# mid-2025 onward) removed outright. The affected code (ui_openssl.c /
# read_pwd.c) is OpenSSL's interactive password-prompt UI, which nothing in
# the game path ever calls, but it still has to compile. Modern OpenSSL made
# the same change upstream: select TERMIOS (<termios.h>, fully supported)
# instead. This can't be done via CFLAGS — the '#if defined(linux)' block
# undefines TERMIOS no matter what you pass — so patch the two files.
for rel in crypto/ui/ui_openssl.c crypto/des/read_pwd.c; do
    SSL_FILE="$SRC/3rdparty/openssl-1.0.0m/$rel"
    [ -f "$SSL_FILE" ] || continue
    python3 - "$SSL_FILE" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
pairs = [
    # ui_openssl.c style (space after '#')
    ("#if defined(linux) && !defined(TERMIO)\n# undef  TERMIOS\n# define TERMIO\n# undef  SGTTY\n#endif",
     "#if defined(linux) && !defined(TERMIO)\n# define TERMIOS\n# undef  TERMIO\n# undef  SGTTY\n#endif"),
    # read_pwd.c style (no space after '#')
    ("#if defined(linux) && !defined(TERMIO)\n#undef  TERMIOS\n#define TERMIO\n#undef  SGTTY\n#endif",
     "#if defined(linux) && !defined(TERMIO)\n#define TERMIOS\n#undef  TERMIO\n#undef  SGTTY\n#endif"),
]
orig = s
for a, b in pairs:
    s = s.replace(a, b)
if s != orig:
    open(p, "w").write(s)
    print(f"  patched {p.split('3rdparty/')[-1]} (TERMIO -> TERMIOS)")
else:
    print(f"  {p.split('3rdparty/')[-1]}: pattern not found or already patched")
PY
done

# Patch 8: don't build the vendored SDL 2.0.0 (2013) at all. Its GL renderer
# (SDL_render_gl.c) declares GL debug-callback types that conflict with a
# modern /usr/include/GL/glext.h — a hard error on current GCC. Nothing needs
# it: untz was already switched to system SDL2 (Patch 3), and the SDL host
# (host-sdl) is only added when SDL_HOST is set — this build uses host-glut.
# The static lib was being compiled by 'make all' and then linked by nothing.
# Replace the whole subproject with an INTERFACE wrapper around system SDL2,
# keeping the target name 'SDL2-static' so host-sdl would still link if
# anyone enables it. Bonus: kills ~200 SDL platform checks at configure time.
SDL2_CMAKE="$SRC/cmake/third-party/sdl2/CMakeLists.txt"
if [ -f "$SDL2_CMAKE" ]; then
    cat > "$SDL2_CMAKE" <<'CMAKE'
# csp-restore: use system SDL2 instead of bundled sdl2-2.0.0 (its GL renderer
# won't compile against modern glext.h, and nothing in this build links it).
cmake_minimum_required ( VERSION 3.5 )
project ( sdl2 )
find_package ( PkgConfig REQUIRED )
pkg_check_modules ( SYS_SDL2 REQUIRED sdl2 )
add_library ( SDL2-static INTERFACE )
target_include_directories ( SDL2-static INTERFACE ${SYS_SDL2_INCLUDE_DIRS} )
target_link_libraries ( SDL2-static INTERFACE ${SYS_SDL2_LINK_LIBRARIES} )
CMAKE
    echo "  patched third-party/sdl2 (system SDL2, vendored build disabled)"
fi

# Patch 9: MOAI adds the third-party curl and luacurl subdirectories
# unconditionally, so 'make all' builds them even with -DMOAI_CURL=FALSE —
# and nothing links them in that configuration (moai-sim and moai-luaext both
# gate their curl/luacurl links behind MOAI_CURL). Vendored curl runs its own
# 2010-era autoconf configure at build time, whose "libs available at
# link-time are not available run-time" self-test fails on modern systems.
# Gate both subdirectories behind MOAI_CURL so the dead code never configures.
TP_CMAKE="$SRC/cmake/third-party/CMakeLists.txt"
if [ -f "$TP_CMAKE" ] && ! grep -q "csp-restore: curl gated" "$TP_CMAKE"; then
    python3 - "$TP_CMAKE" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace(
    "add_subdirectory ( curl )",
    "if (MOAI_CURL) # csp-restore: curl gated\n"
    "  add_subdirectory ( curl )\n"
    "endif (MOAI_CURL)",
)
open(p, "w").write(s)
print("  patched third-party/CMakeLists.txt (curl gated behind MOAI_CURL)")
PY
fi
LUAEXT_CMAKE="$SRC/cmake/third-party/luaext/CMakeLists.txt"
if [ -f "$LUAEXT_CMAKE" ] && ! grep -q "csp-restore: luacurl gated" "$LUAEXT_CMAKE"; then
    python3 - "$LUAEXT_CMAKE" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace(
    "add_subdirectory ( luacurl )",
    "if (MOAI_CURL) # csp-restore: luacurl gated\n"
    "  add_subdirectory ( luacurl )\n"
    "endif (MOAI_CURL)",
)
open(p, "w").write(s)
print("  patched luaext/CMakeLists.txt (luacurl gated behind MOAI_CURL)")
PY
fi

# Patch 10: luasql 2.2.0 has a real bug — opts_settimeout passes the Lua
# wrapper struct (conn_data*) to sqlite3_busy_timeout instead of the raw
# sqlite3* handle (conn->sql_conn), unlike every other call site in the file.
# GCC 14+ promoted incompatible-pointer-types to a hard error, so this now
# stops the build. (Upstream luasql fixed the same bug in later releases.)
LUASQL_C="$SRC/3rdparty/luasql-2.2.0/src/ls_sqlite3.c"
if [ -f "$LUASQL_C" ]; then
    sed -i 's|sqlite3_busy_timeout(conn, milisseconds)|sqlite3_busy_timeout(conn->sql_conn, milisseconds)|' "$LUASQL_C"
    echo "  patched luasql ls_sqlite3.c (sqlite3_busy_timeout wrong pointer)"
fi

echo "== Configuring (cmake) =="
# IMPORTANT: point cmake at the top-level cmake/ directory, NOT cmake/host-glut.
# The top-level CMakeLists sets MOAI_ROOT and adds every library subdirectory
# plus the host. Pointing directly at host-glut leaves MOAI_ROOT empty, so its
# source glob ("${MOAI_ROOT}/src/host-glut/Glut*.cpp") matches nothing and you
# get "No SOURCES given to target: moai". This mirrors MOAI's own
# bin/build-linux-glut.sh.
BUILD="$SRC/cmake/build"

# MOAI 1.5 is ~2014 C++ built here with a modern (2025+) GCC/Clang. Several
# things that were warnings then are hard errors now. Relax the most common
# ones back to warnings so the build can complete. If your compiler still
# errors out, the offending diagnostic is usually named in the message — add
# its -Wno-error=<name> counterpart here.
export CXXFLAGS="${CXXFLAGS:-} -fpermissive -w \
  -Wno-error=narrowing -Wno-error=register \
  -Wno-error=deprecated-declarations \
  -Wno-error=implicit-function-declaration \
  -std=gnu++14"
export CFLAGS="${CFLAGS:-} -w -Wno-error=implicit-function-declaration \
  -Wno-error=incompatible-pointer-types -Wno-error=int-conversion \
  -Wno-error=implicit-int -Wno-error=return-mismatch"

rm -rf "$BUILD"
mkdir -p "$BUILD"
cd "$BUILD"
# MOAI 1.5's CMakeLists declares a very old cmake_minimum_required (pre-3.5).
# CMake 4.x removed compatibility for that and hard-errors. This flag tells
# CMake to treat the old minimum as 3.5 and configure anyway. Harmless on
# older CMake.
cmake \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DOpenGL_GL_PREFERENCE=LEGACY \
  -DBUILD_LINUX=TRUE \
  -DBUILD_HOST=TRUE \
  -DMOAI_BOX2D=TRUE -DMOAI_CHIPMUNK=TRUE \
  -DMOAI_CURL=FALSE -DMOAI_CRYPTO=TRUE -DMOAI_EXPAT=TRUE \
  -DMOAI_FREETYPE=TRUE -DMOAI_JSON=TRUE -DMOAI_JPG=TRUE \
  -DMOAI_LUAEXT=TRUE -DMOAI_OGG=TRUE -DMOAI_OPENSSL=FALSE \
  -DMOAI_SQLITE3=TRUE -DMOAI_TINYXML=TRUE -DMOAI_PNG=TRUE \
  -DMOAI_SFMT=TRUE -DMOAI_VORBIS=TRUE -DMOAI_UNTZ=TRUE \
  -DMOAI_LUAJIT=FALSE -DMOAI_HTTP_CLIENT=FALSE \
  -DMOAI_MONGOOSE=FALSE -DCMAKE_BUILD_TYPE=Release \
  ..

echo "== Building =="
make -j "$(nproc)" || {
    echo "" >&2
    echo "== Parallel build failed — re-running serially so the real error" >&2
    echo "== is the last thing printed (parallel output buries it) ==" >&2
    make -j1
}

# The host binary lands at <build>/host-glut/moai. Search for an executable
# named exactly 'moai' (avoid matching library directories).
BIN="$(find "$BUILD" -type f -name moai -executable | head -1)"
[ -n "$BIN" ] || { echo "build produced no 'moai' binary" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"
cp "$BIN" "$OUT"
echo "== Done: $OUT =="
file "$OUT"

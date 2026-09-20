#!/bin/bash
# build.sh — Cross-compile fully-static FFmpeg + all dependencies
# Supports: ARCH=aarch64 (default), ARCH=x86_64
#           TARGET_OS=linux (default), TARGET_OS=windows
#           ARCH_CFLAGS for target-specific tuning (e.g. "-mcpu=cortex-a76" for RPi5)
set -euo pipefail

PREFIX="${PREFIX:-/tmp/ffmpeg-deps}"
SRC="${SRC:-/tmp/src}"
FFMPEG_SRC="${FFMPEG_SRC:-$SRC/ffmpeg}"

# Architecture and OS selection — override via env
ARCH="${ARCH:-aarch64}"
ARCH_CFLAGS="${ARCH_CFLAGS:-}"
TARGET_OS="${TARGET_OS:-linux}"
VARIANT_LABEL="${VARIANT_LABEL:-static}"

if [ "$TARGET_OS" = "windows" ]; then
  CROSS_PREFIX="x86_64-w64-mingw32-"
  HOST="x86_64-w64-mingw32"
else
  CROSS_PREFIX="${ARCH}-linux-musl-"
  HOST="${ARCH}-linux-musl"
fi
CROSS_CC="${CROSS_PREFIX}gcc"
CROSS_CXX="${CROSS_PREFIX}g++"
CROSS_AR="${CROSS_PREFIX}ar"
CROSS_RANLIB="${CROSS_PREFIX}ranlib"
CROSS_STRIP="${CROSS_PREFIX}strip"
CROSS_NM="${CROSS_PREFIX}nm"
NPROC=$(nproc)

# Arch-dependent values for build systems
if [ "$TARGET_OS" = "windows" ]; then
  CMAKE_PROC=x86_64; MESON_CPU=x86_64; VPX_TARGET=x86_64-win64-gcc; AOM_CPU=x86_64; FFMPEG_ARCH=x86_64
  CMAKE_SYSTEM_NAME=Windows
  MESON_SYSTEM=windows
else
  case "$ARCH" in
    aarch64) CMAKE_PROC=aarch64; MESON_CPU=aarch64; VPX_TARGET=arm64-linux-gcc; AOM_CPU=arm64; FFMPEG_ARCH=aarch64 ;;
    x86_64)  CMAKE_PROC=x86_64;  MESON_CPU=x86_64;  VPX_TARGET=x86_64-linux-gcc; AOM_CPU=x86_64; FFMPEG_ARCH=x86_64 ;;
    *) echo "FATAL: unsupported ARCH=$ARCH"; exit 1 ;;
  esac
  CMAKE_SYSTEM_NAME=Linux
  MESON_SYSTEM=linux
fi

log_arch() { echo "=== Building for $ARCH${ARCH_CFLAGS:+ ($ARCH_CFLAGS)} ==="; }
log_arch

# Only export pkg-config paths — these affect library discovery, not compilation
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"

mkdir -p "$PREFIX/lib/pkgconfig" "$SRC"

# ── Shared toolchain/cross files ──

cat > "$SRC/toolchain.cmake" <<EOF
set(CMAKE_SYSTEM_NAME $CMAKE_SYSTEM_NAME)
set(CMAKE_SYSTEM_PROCESSOR $CMAKE_PROC)
set(CMAKE_C_COMPILER $CROSS_CC)
set(CMAKE_CXX_COMPILER $CROSS_CXX)
set(CMAKE_AR $CROSS_AR CACHE FILEPATH "")
set(CMAKE_RANLIB $CROSS_RANLIB CACHE FILEPATH "")
set(CMAKE_NM $CROSS_NM CACHE FILEPATH "")
set(CMAKE_FIND_ROOT_PATH $PREFIX)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_INSTALL_LIBDIR lib)
${ARCH_CFLAGS:+set(CMAKE_C_FLAGS_INIT "$ARCH_CFLAGS")}
${ARCH_CFLAGS:+set(CMAKE_CXX_FLAGS_INIT "$ARCH_CFLAGS")}
EOF

cat > "$SRC/cross.ini" <<EOF
[binaries]
c = '$CROSS_CC'
cpp = '$CROSS_CXX'
ar = '$CROSS_AR'
strip = '$CROSS_STRIP'
nm = '$CROSS_NM'
pkgconfig = 'pkg-config'

[properties]
pkg_config_libdir = ['$PREFIX/lib/pkgconfig']

[built-in options]
default_library = 'static'
${ARCH_CFLAGS:+c_args = ['$(echo $ARCH_CFLAGS | sed "s/ /', '/g")']}
${ARCH_CFLAGS:+cpp_args = ['$(echo $ARCH_CFLAGS | sed "s/ /', '/g")']}

[host_machine]
system = '$MESON_SYSTEM'
cpu_family = '$MESON_CPU'
cpu = '$MESON_CPU'
endian = 'little'
EOF

TCMAKE="$SRC/toolchain.cmake"
MCROSS="$SRC/cross.ini"
VERSIONS="$SRC/versions.txt"
: > "$VERSIONS"

log() { printf '\n══════ %s ══════\n\n' "$1"; }

# Record a library version: ver <name> <version>
ver() { printf '%-20s %s\n' "$1" "$2" >> "$VERSIONS"; }

do_cmake() {
  local src="$1"; shift
  cmake "$src" \
    -DCMAKE_TOOLCHAIN_FILE="$TCMAKE" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    "$@"
}

# ════════════════════════════════════════════════════════════════════
# TIER 0 — Foundation
# ════════════════════════════════════════════════════════════════════

log "zlib 1.3.2"
cd "$SRC"
wget -q "$URL_ZLIB"
tar xzf zlib-1.3.2.tar.gz && cd zlib-1.3.2
CC="$CROSS_CC" AR="$CROSS_AR" RANLIB="$CROSS_RANLIB" \
  ./configure --prefix="$PREFIX" --static
make -j"$NPROC"
make install
ver "zlib" "1.3.2"

log "bzip2 1.0.8"
cd "$SRC"
wget -q https://sourceware.org/pub/bzip2/bzip2-1.0.8.tar.gz
tar xzf bzip2-1.0.8.tar.gz && cd bzip2-1.0.8
make -j"$NPROC" \
  CC="$CROSS_CC" AR="$CROSS_AR" RANLIB="$CROSS_RANLIB" \
  CFLAGS="-O2 -fPIC" libbz2.a
install -m644 libbz2.a "$PREFIX/lib/"
install -m644 bzlib.h "$PREFIX/include/"
ver "bzip2" "1.0.8"

log "libpng 1.6.58"
cd "$SRC"
wget -q -O libpng-1.6.58.tar.gz \
  "https://downloads.sourceforge.net/project/libpng/libpng16/1.6.58/libpng-1.6.58.tar.gz"
tar xzf libpng-1.6.58.tar.gz && cd libpng-1.6.58
CPPFLAGS="-I$PREFIX/include" LDFLAGS="-L$PREFIX/lib" \
  ./configure --prefix="$PREFIX" --host="$HOST" \
  --enable-static --disable-shared
make -j"$NPROC"
make install
ver "libpng" "1.6.58"

log "libogg 1.3.6"
cd "$SRC"
wget -q https://downloads.xiph.org/releases/ogg/libogg-1.3.6.tar.gz
tar xzf libogg-1.3.6.tar.gz && cd libogg-1.3.6
./configure --prefix="$PREFIX" --host="$HOST" \
  --enable-static --disable-shared
make -j"$NPROC"
make install
ver "libogg" "1.3.6"

# ════════════════════════════════════════════════════════════════════
# TIER 1 — Audio codecs
# ════════════════════════════════════════════════════════════════════

log "libvorbis 1.3.7"
cd "$SRC"
wget -q https://downloads.xiph.org/releases/vorbis/libvorbis-1.3.7.tar.gz
tar xzf libvorbis-1.3.7.tar.gz && cd libvorbis-1.3.7
./configure --prefix="$PREFIX" --host="$HOST" \
  --enable-static --disable-shared \
  --with-ogg="$PREFIX"
make -j"$NPROC"
make install
ver "libvorbis" "1.3.7"

log "opus 1.6.1"
cd "$SRC"
# Release tarball ships configure and the DNN weight files, so no autogen.sh
# (which downloads a model tarball from media.xiph.org at build time)
wget -q https://downloads.xiph.org/releases/opus/opus-1.6.1.tar.gz
tar xzf opus-1.6.1.tar.gz && cd opus-1.6.1
./configure --prefix="$PREFIX" --host="$HOST" \
  --enable-static --disable-shared \
  --disable-doc --disable-extra-programs
make -j"$NPROC"
make install
ver "opus" "1.6.1"

log "lame 4.0"
cd "$SRC"
wget -q -O lame-4.0.tar.gz \
  "https://downloads.sourceforge.net/project/lame/lame/4.0/lame-4.0.tar.gz"
tar xzf lame-4.0.tar.gz && cd lame-4.0
# --disable-decoder: since 3.101 the decoder needs an external libmpg123
# (configure errors out without it); FFmpeg only uses the encoder.
./configure --prefix="$PREFIX" --host="$HOST" \
  --enable-static --disable-shared --disable-frontend --disable-decoder
make -j"$NPROC"
make install
ver "lame" "4.0"

log "speex 1.2.1"
cd "$SRC"
wget -q https://downloads.xiph.org/releases/speex/speex-1.2.1.tar.gz
tar xzf speex-1.2.1.tar.gz && cd speex-1.2.1
./configure --prefix="$PREFIX" --host="$HOST" \
  --enable-static --disable-shared --disable-binaries
make -j"$NPROC"
make install
ver "speex" "1.2.1"

log "opencore-amr 0.1.6"
cd "$SRC"
wget -q -O opencore-amr-0.1.6.tar.gz \
  "https://downloads.sourceforge.net/project/opencore-amr/opencore-amr/opencore-amr-0.1.6.tar.gz"
tar xzf opencore-amr-0.1.6.tar.gz && cd opencore-amr-0.1.6
./configure --prefix="$PREFIX" --host="$HOST" \
  --enable-static --disable-shared
make -j"$NPROC"
make install
ver "opencore-amr" "0.1.6"

log "vo-amrwbenc 0.1.3"
cd "$SRC"
wget -q -O vo-amrwbenc-0.1.3.tar.gz \
  "https://downloads.sourceforge.net/project/opencore-amr/vo-amrwbenc/vo-amrwbenc-0.1.3.tar.gz"
tar xzf vo-amrwbenc-0.1.3.tar.gz && cd vo-amrwbenc-0.1.3
cp /usr/share/misc/config.sub .
cp /usr/share/misc/config.guess .
./configure --prefix="$PREFIX" --host="$HOST" \
  --enable-static --disable-shared
make -j"$NPROC"
make install
ver "vo-amrwbenc" "0.1.3"

log "libsoxr 0.1.3"
cd "$SRC"
wget -q -O soxr-0.1.3-Source.tar.xz \
  "https://downloads.sourceforge.net/project/soxr/soxr-0.1.3-Source.tar.xz"
tar xJf soxr-0.1.3-Source.tar.xz && cd soxr-0.1.3-Source
mkdir build && cd build
do_cmake .. -DBUILD_TESTS=OFF -DBUILD_EXAMPLES=OFF -DWITH_OPENMP=OFF
make -j"$NPROC"
make install
ver "libsoxr" "0.1.3"

# ════════════════════════════════════════════════════════════════════
# TIER 2 — Video codecs
# ════════════════════════════════════════════════════════════════════

log "x264 (stable)"
cd "$SRC"
git clone --depth 1 --branch stable https://code.videolan.org/videolan/x264.git
cd x264
./configure --prefix="$PREFIX" --host="$HOST" \
  --cross-prefix="${CROSS_PREFIX}" \
  --enable-static --disable-shared \
  --disable-cli --enable-pic
make -j"$NPROC"
make install
ver "x264" "$(git rev-parse --short HEAD)"

log "x265 4.3"
cd "$SRC"
git clone --depth 1 --branch 4.3 https://github.com/Multicorewareinc/x265.git x265_git
cd x265_git
X265_VER="4.3"
mkdir -p build/cross && cd build/cross
do_cmake ../../source \
  -DENABLE_SHARED=OFF -DENABLE_CLI=OFF \
  -DENABLE_LIBNUMA=OFF
cmake --build . -j "$NPROC"
echo "=== x265: .a files in build tree ==="
find . -name "*.a" -type f
cmake --install . --prefix "$PREFIX" -v 2>&1 || true
if [ ! -f "$PREFIX/lib/libx265.a" ]; then
  echo "libx265.a missing from $PREFIX/lib — searching build tree"
  X265_A=$(find . -name "libx265.a" -print -quit)
  if [ -n "$X265_A" ]; then
    cp -v "$X265_A" "$PREFIX/lib/"
  else
    echo "FATAL: libx265.a not found after build"
    find . -type f -name "*.a" | head -20
    exit 1
  fi
fi
if [ ! -f "$PREFIX/include/x265.h" ]; then
  cp ../../source/x265.h "$PREFIX/include/"
  cp x265_config.h "$PREFIX/include/"
fi
# Always write our own x265.pc — cmake's may lack Libs.private flags
cat > "$PREFIX/lib/pkgconfig/x265.pc" <<X265PC
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: x265
Description: H.265/HEVC video encoder
Version: $X265_VER
Libs: -L\${libdir} -lx265
Libs.private: -lstdc++ -lm -lpthread -ldl
Cflags: -I\${includedir}
X265PC
# Windows has no libdl
[ "$TARGET_OS" = "windows" ] && sed -i 's/ -ldl//g' "$PREFIX/lib/pkgconfig/x265.pc"
# Fail fast if libx265.a does not link statically. This mirrors the link test
# FFmpeg's configure runs for --enable-libx265 (whose failure is opaque and
# comes ~30 minutes later). Keep the trailing flags in sync with the FFmpeg
# --extra-ldflags / --extra-libs below.
echo "=== x265: static link check ==="
cat > /tmp/x265test.c <<'X265TEST'
#include <x265.h>
int main(void) { const x265_api *api = x265_api_get(0); return api ? 0 : 1; }
X265TEST
if [ "$TARGET_OS" = "windows" ]; then
  X265_TEST_LD="-static -static-libgcc -static-libstdc++ -lstdc++ -lpthread -lm -lws2_32 -liphlpapi -lbcrypt -lcrypt32 -lsecur32"
else
  X265_TEST_LD="-static -lstdc++ -lpthread -lm -latomic"
fi
if ! "$CROSS_CC" /tmp/x265test.c \
     $(pkg-config --cflags --static x265) $(pkg-config --libs --static x265) \
     $X265_TEST_LD -o /tmp/x265test_out; then
  echo "FATAL: libx265.a does not link statically — see linker errors above"
  exit 1
fi
rm -f /tmp/x265test.c /tmp/x265test_out
echo "x265 static link: OK"
ver "x265" "$X265_VER"

log "libvpx 1.17.0"
cd "$SRC"
git clone --depth 1 --branch v1.17.0 \
  https://chromium.googlesource.com/webm/libvpx.git
cd libvpx
VPX_AS="${CROSS_PREFIX}as"
[ "$ARCH" = "x86_64" ] && VPX_AS="nasm"
CROSS="${CROSS_PREFIX}" \
CC="$CROSS_CC" CXX="$CROSS_CXX" LD="${CROSS_PREFIX}ld" \
AR="$CROSS_AR" AS="$VPX_AS" STRIP="$CROSS_STRIP" \
  ./configure --prefix="$PREFIX" --target="$VPX_TARGET" \
  --enable-static --disable-shared \
  --disable-examples --disable-tools \
  --disable-unit-tests --disable-docs \
  --enable-pic --enable-vp9-highbitdepth
make -j"$NPROC"
make install
ver "libvpx" "1.17.0"

log "libaom (AV1)"
cd "$SRC"
git clone --depth 1 --branch v3.15.0 \
  https://aomedia.googlesource.com/aom libaom
mkdir libaom-build && cd libaom-build
AOM_EXTRA=""
[ "$ARCH" = "x86_64" ] && AOM_EXTRA="-DENABLE_NASM=ON"
do_cmake ../libaom \
  -DAOM_TARGET_CPU="$AOM_CPU" \
  -DENABLE_TESTS=OFF -DENABLE_EXAMPLES=OFF \
  -DENABLE_DOCS=OFF -DENABLE_TOOLS=OFF -DENABLE_APPS=OFF \
  $AOM_EXTRA
cmake --build . -j "$NPROC"
echo "=== libaom: .a files in build tree ==="
find . -name "*.a" -type f
cmake --install . --prefix "$PREFIX" -v 2>&1 || true
# Verify installation — copy from build tree if cmake install skipped it
if [ ! -f "$PREFIX/lib/libaom.a" ]; then
  echo "libaom.a missing from $PREFIX/lib — searching build tree"
  AOM_A=$(find . -name "libaom.a" -print -quit)
  if [ -n "$AOM_A" ]; then
    cp -v "$AOM_A" "$PREFIX/lib/"
  else
    echo "FATAL: libaom.a not found anywhere after build"
    find . -type f \( -name "*.a" -o -name "*.so" \) | head -20
    exit 1
  fi
fi
if [ ! -d "$PREFIX/include/aom" ]; then
  mkdir -p "$PREFIX/include/aom"
  cp ../libaom/aom/*.h "$PREFIX/include/aom/"
fi
if [ ! -f "$PREFIX/lib/pkgconfig/aom.pc" ]; then
  cat > "$PREFIX/lib/pkgconfig/aom.pc" <<AOMPC
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: aom
Description: Alliance for Open Media AV1 codec library
Version: 3.15.0
Libs: -L\${libdir} -laom
Libs.private: -lm -lpthread
Cflags: -I\${includedir}
AOMPC
fi
ver "libaom" "3.15.0"

log "dav1d (AV1 decoder)"
cd "$SRC"
git clone --depth 1 --branch 1.5.4 \
  https://code.videolan.org/videolan/dav1d.git
cd dav1d
meson setup build --cross-file "$MCROSS" --prefix="$PREFIX" \
  -Denable_tests=false -Denable_examples=false -Denable_tools=false
ninja -C build && ninja -C build install
ver "dav1d" "1.5.4"

log "libtheora 1.2.0"
cd "$SRC"
wget -q https://downloads.xiph.org/releases/theora/libtheora-1.2.0.tar.xz
tar xJf libtheora-1.2.0.tar.xz && cd libtheora-1.2.0
# Keep config.sub/config.guess current for the *-linux-musl triplets
cp /usr/share/misc/config.sub .
cp /usr/share/misc/config.guess .
./configure --prefix="$PREFIX" --host="$HOST" \
  --enable-static --disable-shared \
  --disable-examples --disable-spec --disable-doc \
  --with-ogg="$PREFIX" --with-vorbis="$PREFIX" \
  --disable-asm
make -j"$NPROC"
make install
ver "libtheora" "1.2.0"

log "xvidcore 1.3.7"
cd "$SRC"
wget -q https://downloads.xvid.com/downloads/xvidcore-1.3.7.tar.gz
tar xzf xvidcore-1.3.7.tar.gz && cd xvidcore/build/generic
# xvidcore's configure is non-standard — set CC explicitly
CC="$CROSS_CC" ./configure --prefix="$PREFIX" --host="$HOST"
# Modern mingw-w64 doesn't support the ancient -mno-cygwin flag
[ "$TARGET_OS" = "windows" ] && sed -i 's/-mno-cygwin//g' platform.inc
make -j"$NPROC"
make install
rm -f "$PREFIX/lib/libxvidcore.so"* "$PREFIX/lib/libxvidcore.dylib"* "$PREFIX/lib/libxvidcore.dll"*
# Windows: xvidcore installs as xvidcore.a (no lib prefix) — rename so -lxvidcore finds it
if [ "$TARGET_OS" = "windows" ]; then
  [ -f "$PREFIX/lib/xvidcore.a" ] && mv "$PREFIX/lib/xvidcore.a" "$PREFIX/lib/libxvidcore.a"
  rm -f "$PREFIX/lib/xvidcore.dll.a" "$PREFIX/bin/xvidcore.dll"
fi
ver "xvidcore" "1.3.7"

log "openjpeg 2.5.4"
cd "$SRC"
git clone --depth 1 --branch v2.5.4 \
  https://github.com/uclouvain/openjpeg.git
mkdir openjpeg/build && cd openjpeg/build
do_cmake .. -DBUILD_CODEC=OFF -DBUILD_TESTING=OFF
make -j"$NPROC"
make install
echo "--- libopenjp2.pc ---"; cat "$PREFIX/lib/pkgconfig/libopenjp2.pc" 2>/dev/null || true
ver "openjpeg" "2.5.4"

# ════════════════════════════════════════════════════════════════════
# TIER 3 — Image, processing, misc
# ════════════════════════════════════════════════════════════════════

log "libwebp 1.6.0"
cd "$SRC"
git clone --depth 1 --branch v1.6.0 \
  https://chromium.googlesource.com/webm/libwebp.git
mkdir libwebp/build && cd libwebp/build
do_cmake .. \
  -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF \
  -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF \
  -DWEBP_BUILD_VWEBP=OFF -DWEBP_BUILD_WEBPINFO=OFF \
  -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF \
  -DWEBP_BUILD_ANIM_UTILS=OFF
make -j"$NPROC"
make install
ver "libwebp" "1.6.0"

log "zimg 3.0.6"
cd "$SRC"
git clone --depth 1 --branch release-3.0.6 \
  https://github.com/sekrit-twc/zimg.git
cd zimg && ./autogen.sh
./configure --prefix="$PREFIX" --host="$HOST" \
  --enable-static --disable-shared
make -j"$NPROC"
make install
ver "zimg" "3.0.6"

log "vidstab 1.1.2"
cd "$SRC"
git clone --depth 1 --branch v1.1.2 \
  https://github.com/georgmartius/vid.stab.git
mkdir vid.stab/build && cd vid.stab/build
do_cmake ..
make -j"$NPROC"
make install
ver "vid.stab" "1.1.2"

log "libgme 0.6.5"
cd "$SRC"
git clone --depth 1 --branch 0.6.5 \
  https://github.com/libgme/game-music-emu.git
mkdir game-music-emu/build && cd game-music-emu/build
do_cmake .. -DGME_BUILD_SHARED=OFF -DGME_BUILD_STATIC=ON \
  -DGME_ENABLE_UBSAN=OFF -DGME_BUILD_TESTING=OFF -DGME_BUILD_EXAMPLES=OFF
make -j"$NPROC"
make install
# 0.6.5 fills Libs.private from CMAKE_CXX_IMPLICIT_LINK_LIBRARIES, which drags
# in -lgcc_s/-lgcc/-lc: no static libgcc_s on musl, and a libgcc_s DLL import
# on Windows. Same fixup as srt.pc.
if [ -f "$PREFIX/lib/pkgconfig/libgme.pc" ]; then
  sed -i 's/ -lgcc_s//g; s/ -lgcc\b//g; s/ -lc\b//g' "$PREFIX/lib/pkgconfig/libgme.pc"
  echo "--- libgme.pc after fixup ---"; cat "$PREFIX/lib/pkgconfig/libgme.pc"
fi
ver "libgme" "0.6.5"

# ════════════════════════════════════════════════════════════════════
# TIER 4 — Text & subtitle rendering
# ════════════════════════════════════════════════════════════════════

log "freetype 2.14.3"
cd "$SRC"
wget -q https://download.savannah.gnu.org/releases/freetype/freetype-2.14.3.tar.xz
tar xJf freetype-2.14.3.tar.xz && cd freetype-2.14.3
mkdir build && cd build
do_cmake .. \
  -DFT_REQUIRE_ZLIB=ON -DFT_REQUIRE_PNG=ON \
  -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_HARFBUZZ=ON
make -j"$NPROC"
make install
ver "freetype" "2.14.3"

log "fribidi"
cd "$SRC"
git clone --depth 1 --branch v1.0.17 \
  https://github.com/fribidi/fribidi.git
cd fribidi
meson setup build --cross-file "$MCROSS" --prefix="$PREFIX" \
  -Ddocs=false -Dtests=false
ninja -C build && ninja -C build install
ver "fribidi" "1.0.17"

log "harfbuzz 14.4.0"
cd "$SRC"
git clone --depth 1 --branch 14.4.0 \
  https://github.com/harfbuzz/harfbuzz.git
cd harfbuzz
# harfbuzz >= 13 enables extra sub-libraries by default (raster, vector,
# gpu — which needs host python3 — subset, utilities). FFmpeg and libass only
# need the core shaper, so keep the build to libharfbuzz.a.
meson setup build --cross-file "$MCROSS" --prefix="$PREFIX" \
  -Dfreetype=enabled -Dglib=disabled -Dgobject=disabled \
  -Dcairo=disabled -Dicu=disabled -Dcoretext=disabled \
  -Draster=disabled -Dvector=disabled -Dgpu=disabled -Dgpu_demo=disabled \
  -Dsubset=disabled -Dutilities=disabled \
  -Dtests=disabled -Ddocs=disabled -Dbenchmark=disabled
ninja -C build && ninja -C build install
ver "harfbuzz" "14.4.0"

log "libass 0.17.5"
cd "$SRC"
git clone --depth 1 --branch 0.17.5 \
  https://github.com/libass/libass.git
cd libass && ./autogen.sh
CPPFLAGS="-I$PREFIX/include" LDFLAGS="-L$PREFIX/lib" \
  ./configure --prefix="$PREFIX" --host="$HOST" \
  --enable-static --disable-shared \
  --disable-fontconfig \
  --disable-require-system-font-provider
make -j"$NPROC"
make install
ver "libass" "0.17.5"

if [ "$TARGET_OS" != "windows" ]; then
log "libzvbi 0.2.45"
cd "$SRC"
git clone --depth 1 --branch v0.2.45 https://github.com/zapping-vbi/zvbi.git
cd zvbi
ZVBI_VER="0.2.45"
autoreconf -fi
CPPFLAGS="-I$PREFIX/include" LDFLAGS="-L$PREFIX/lib" \
  ac_cv_func_malloc_0_nonnull=yes ac_cv_func_realloc_0_nonnull=yes \
  ./configure --prefix="$PREFIX" --host="$HOST" \
  --enable-static --disable-shared \
  --without-doxygen --without-x --disable-nls
# Build only the library — full build tries to compile tools/daemon that
# pull in missing host deps and fail under cross-compilation
make -j"$NPROC" -C src
make -C src install
# Install pkg-config file from top-level (not handled by src-only install)
if [ -f zvbi-0.2.pc ]; then
  install -Dm644 zvbi-0.2.pc "$PREFIX/lib/pkgconfig/"
fi
ver "libzvbi" "$ZVBI_VER"
fi

# ════════════════════════════════════════════════════════════════════
# TIER 5 — TLS & network
# ════════════════════════════════════════════════════════════════════

if [ "$TARGET_OS" != "windows" ]; then
log "gmp 6.3.0"
cd "$SRC"
wget -q "$URL_GMP"
tar xJf gmp-6.3.0.tar.xz && cd gmp-6.3.0
# CC_FOR_BUILD=gcc: GMP builds host-side generators (gen-fib, gen-bases)
# that must run on x86_64, not the cross target
CC_FOR_BUILD=gcc \
  ./configure --prefix="$PREFIX" --host="$HOST" --build=x86_64-linux-gnu \
  --enable-static --disable-shared
make -j"$NPROC"
make install
ver "gmp" "6.3.0"

log "nettle 3.10.2"
cd "$SRC"
wget -q https://ftp.gnu.org/gnu/nettle/nettle-3.10.2.tar.gz
tar xzf nettle-3.10.2.tar.gz && cd nettle-3.10.2
# CC_FOR_BUILD: nettle builds host-side tools (desdata, eccdata)
NETTLE_EXTRA=""
[ "$ARCH" = "aarch64" ] && NETTLE_EXTRA="--disable-fat"
CC_FOR_BUILD=gcc \
CFLAGS="-O2 -fPIC" CPPFLAGS="-I$PREFIX/include" LDFLAGS="-L$PREFIX/lib" \
  ./configure --prefix="$PREFIX" --host="$HOST" \
  --enable-static --disable-shared \
  --disable-documentation $NETTLE_EXTRA
# On aarch64: nettle sets CCPIC=-fpic (small GOT model) which overflows
# when linked into a fully-static FFmpeg. Replace with -fPIC (large model).
[ "$ARCH" = "aarch64" ] && sed -i 's/-fpic/-fPIC/g' config.make
make -j"$NPROC"
make install
ver "nettle" "3.10.2"

log "gnutls 3.8.13"
cd "$SRC"
wget -q https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/gnutls-3.8.13.tar.xz
tar xJf gnutls-3.8.13.tar.xz && cd gnutls-3.8.13
CC_FOR_BUILD=gcc \
CPPFLAGS="-I$PREFIX/include" LDFLAGS="-L$PREFIX/lib" \
  ./configure --prefix="$PREFIX" --host="$HOST" \
  --enable-static --disable-shared \
  --with-included-unistring --with-included-libtasn1 \
  --without-p11-kit --without-tpm --without-tpm2 \
  --without-brotli --without-zstd --without-zlib \
  --disable-tests --disable-doc --disable-tools \
  --disable-cxx --disable-nls \
  GMP_CFLAGS="-I$PREFIX/include" GMP_LIBS="-L$PREFIX/lib -lgmp" \
  NETTLE_CFLAGS="-I$PREFIX/include" NETTLE_LIBS="-L$PREFIX/lib -lnettle" \
  HOGWEED_CFLAGS="-I$PREFIX/include" HOGWEED_LIBS="-L$PREFIX/lib -lhogweed -lnettle -lgmp"
make -j"$NPROC"
make install
# Fix gnutls.pc — bundled libtasn1/libunistring may appear in Requires.private
# causing pkg-config --exists to fail when those .pc files don't exist.
# Two-pronged fix: clean up Requires AND provide stub .pc files as fallback.
if [ -f "$PREFIX/lib/pkgconfig/gnutls.pc" ]; then
  sed -i '/^Requires/s/libtasn1//g' "$PREFIX/lib/pkgconfig/gnutls.pc"
  sed -i '/^Requires/s/libunistring//g' "$PREFIX/lib/pkgconfig/gnutls.pc"
  sed -i '/^Requires/s/,[ ]*,/,/g; /^Requires/s/,[ ]*$//; /^Requires/s/:[ ]*,/:/g' "$PREFIX/lib/pkgconfig/gnutls.pc"
  echo "=== gnutls.pc after fixup ==="
  cat "$PREFIX/lib/pkgconfig/gnutls.pc"
fi
# Stub .pc files for bundled deps — satisfies pkg-config if still referenced
for stubpkg in libtasn1 libunistring; do
  cat > "$PREFIX/lib/pkgconfig/${stubpkg}.pc" <<STUBEOF
Name: ${stubpkg}
Description: Bundled into GnuTLS (stub)
Version: 0
Libs:
Cflags:
STUBEOF
done
# Verify gnutls resolves before continuing
pkg-config --print-errors --exists gnutls || { echo "FATAL: gnutls still not found by pkg-config"; ls "$PREFIX/lib/pkgconfig/"*gnutls* "$PREFIX/lib/pkgconfig/"*nettle* "$PREFIX/lib/pkgconfig/"*hogweed* "$PREFIX/lib/pkgconfig/"*gmp* 2>/dev/null; exit 1; }
ver "gnutls" "3.8.13"
fi # TARGET_OS != windows

if [ "$TARGET_OS" = "windows" ]; then
log "mbedTLS 3.6.7"
cd "$SRC"
git clone --depth 1 --branch v3.6.7 --recurse-submodules https://github.com/Mbed-TLS/mbedtls.git
mkdir mbedtls/build && cd mbedtls/build
do_cmake .. \
  -DENABLE_TESTING=OFF -DENABLE_PROGRAMS=OFF \
  -DUSE_SHARED_MBEDTLS_LIBRARY=OFF -DUSE_STATIC_MBEDTLS_LIBRARY=ON
make -j"$NPROC"
make install
ver "mbedtls" "3.6.7"
fi

log "libsrt 1.5.7"
cd "$SRC"
git clone --depth 1 --branch v1.5.7 https://github.com/Haivision/srt.git
mkdir srt/build && cd srt/build
SRT_ENCLIB=gnutls
[ "$TARGET_OS" = "windows" ] && SRT_ENCLIB=mbedtls
do_cmake .. \
  -DENABLE_APPS=OFF -DENABLE_TESTING=OFF \
  -DENABLE_SHARED=OFF \
  -DUSE_ENCLIB="$SRT_ENCLIB" \
  -DCMAKE_PREFIX_PATH="$PREFIX"
make -j"$NPROC"
make install
# Fix srt.pc for static linking
if [ -f "$PREFIX/lib/pkgconfig/srt.pc" ]; then
  if [ "$TARGET_OS" = "windows" ]; then
    # SRT cmake puts absolute paths to mbedtls .a files in Libs.private
    # (e.g. /tmp/.../libmbedtls.a) — FFmpeg's test_ld() misclassifies these
    # (not -l* or *.so) breaking link order. Strip them and use Requires.private.
    sed -i 's| /[^ ]*libmbedtls[^ ]*\.a||g; s| /[^ ]*libmbedcrypto[^ ]*\.a||g; s| /[^ ]*libmbedx509[^ ]*\.a||g' "$PREFIX/lib/pkgconfig/srt.pc"
    # Strip compiler-internal libs — conflicts with -static-libgcc (duplicate _Unwind_Resume)
    sed -i 's/ -lgcc_s//g; s/ -lgcc//g' "$PREFIX/lib/pkgconfig/srt.pc"
    # Ensure Windows socket libs and C++ runtime are present
    if ! grep -q ws2_32 "$PREFIX/lib/pkgconfig/srt.pc"; then
      sed -i '/^Libs\.private:/s/$/ -lws2_32/' "$PREFIX/lib/pkgconfig/srt.pc"
    fi
    if ! grep -q lstdc++ "$PREFIX/lib/pkgconfig/srt.pc"; then
      sed -i '/^Libs\.private:/s/$/ -lstdc++ -lpthread/' "$PREFIX/lib/pkgconfig/srt.pc"
    fi
    # Add mbedtls to Requires.private (check Requires line only, not Libs.private)
    if ! grep -q '^Requires\.private:.*mbedtls' "$PREFIX/lib/pkgconfig/srt.pc"; then
      if grep -q '^Requires\.private:' "$PREFIX/lib/pkgconfig/srt.pc"; then
        sed -i '/^Requires\.private:/s/$/ mbedtls mbedx509 mbedcrypto/' "$PREFIX/lib/pkgconfig/srt.pc"
      else
        echo "Requires.private: mbedtls mbedx509 mbedcrypto" >> "$PREFIX/lib/pkgconfig/srt.pc"
      fi
    fi
  else
    # Remove compiler-internal libs — no static versions in musl
    sed -i 's/ -lgcc_s//g; s/ -lgcc//g; s/ -lc//g' "$PREFIX/lib/pkgconfig/srt.pc"
    if ! grep -q gnutls "$PREFIX/lib/pkgconfig/srt.pc"; then
      if grep -q '^Requires\.private:' "$PREFIX/lib/pkgconfig/srt.pc"; then
        sed -i '/^Requires\.private:/s/$/ gnutls/' "$PREFIX/lib/pkgconfig/srt.pc"
      else
        echo "Requires.private: gnutls" >> "$PREFIX/lib/pkgconfig/srt.pc"
      fi
    fi
  fi
fi
ver "libsrt" "1.5.7"

# ════════════════════════════════════════════════════════════════════
# TIER 6 — Quality metrics & audio processing
# ════════════════════════════════════════════════════════════════════

log "libvmaf 3.2.1"
cd "$SRC"
git clone --depth 1 --branch v3.2.1 https://github.com/Netflix/vmaf.git
cd vmaf/libvmaf
meson setup build --cross-file "$MCROSS" --prefix="$PREFIX" \
  -Denable_tests=false -Denable_docs=false \
  -Dbuilt_in_models=true
ninja -C build && ninja -C build install
ver "libvmaf" "3.2.1"

log "rubberband 4.0.0"
cd "$SRC"
git clone --depth 1 --branch v4.0.0 \
  https://github.com/breakfastquay/rubberband.git
cd rubberband
meson setup build --cross-file "$MCROSS" --prefix="$PREFIX" \
  -Dfft=builtin -Dresampler=builtin \
  -Dcmdline=disabled -Djni=disabled \
  -Dlv2=disabled -Dvamp=disabled
ninja -C build && ninja -C build install
ver "rubberband" "4.0.0"

# ════════════════════════════════════════════════════════════════════
# FINAL — FFmpeg
# ════════════════════════════════════════════════════════════════════

log "FFmpeg"
cd "$FFMPEG_SRC"
FFMPEG_GIT_VER="$(git rev-parse --short HEAD)"
FFMPEG_RELEASE="$(cat RELEASE)"   # e.g. 9.0.2 — what version.sh reports once .git is gone
# Remove .git so version.sh uses the RELEASE file (e.g. 9.0.2) instead of a git-describe hash
rm -rf .git

# Collect any .pc files installed outside $PREFIX/lib/pkgconfig (e.g. lib64/pkgconfig/)
find "$PREFIX" -path "*/pkgconfig/*.pc" ! -path "$PREFIX/lib/pkgconfig/*" \
  -exec cp -v {} "$PREFIX/lib/pkgconfig/" \;
echo "=== pkg-config packages available ==="
ls "$PREFIX/lib/pkgconfig/"

echo "=== Pre-flight pkg-config checks ==="
if [ "$TARGET_OS" = "windows" ]; then
  PREFLIGHT_DEPS="aom x265 libass vpx x264 dav1d opus"
else
  PREFLIGHT_DEPS="aom x265 gnutls libass vpx x264 dav1d opus"
fi
for dep in $PREFLIGHT_DEPS; do
  printf '%-12s ' "$dep:"
  pkg-config --exists "$dep" 2>&1 && printf "exists " || printf "MISSING "
  pkg-config --modversion "$dep" 2>/dev/null || printf "no-version"
  echo
done
echo "--- aom.pc content ---"
cat "$PREFIX/lib/pkgconfig/aom.pc" 2>/dev/null || echo "FILE NOT FOUND"
echo "--- libaom.a location ---"
find "$PREFIX" -name "libaom*" -type f 2>/dev/null || echo "NOT FOUND"
echo "--- aom headers ---"
find "$PREFIX" -name "aom_codec.h" 2>/dev/null || echo "NOT FOUND"
echo "--- test compile+link aom ---"
echo '#include <aom/aom_codec.h>
int main(){aom_codec_version();return 0;}' > /tmp/aomtest.c
"${CROSS_PREFIX}gcc" /tmp/aomtest.c -I"$PREFIX/include" -L"$PREFIX/lib" \
  $(pkg-config --cflags --static aom 2>/dev/null) \
  $(pkg-config --libs --static aom 2>/dev/null) \
  -static -lm -lpthread -o /tmp/aomtest_out 2>&1 && echo "LINK: OK" || echo "LINK: FAIL"
rm -f /tmp/aomtest_out /tmp/aomtest.c
echo "=== End pre-flight ==="

if [ "$TARGET_OS" = "windows" ]; then
echo "=== Windows debug: PREFIX structure ==="
find "$PREFIX/lib" -type f -name "*.a" | sort
echo "--- headers ---"
find "$PREFIX/include" -type f -name "*.h" | head -60 || true
echo "--- srt.pc content ---"
cat "$PREFIX/lib/pkgconfig/srt.pc" 2>/dev/null || echo "FILE NOT FOUND"
echo "--- x265.pc content ---"
cat "$PREFIX/lib/pkgconfig/x265.pc" 2>/dev/null || echo "FILE NOT FOUND"
echo "=== End Windows debug ==="
fi

if [ "$TARGET_OS" = "windows" ]; then
PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" \
PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig" \
./configure \
  --arch="$FFMPEG_ARCH" \
  --extra-version="static-${VARIANT_LABEL}" \
  --target-os=mingw32 \
  --cross-prefix="${CROSS_PREFIX}" \
  --pkg-config=pkg-config \
  --pkg-config-flags="--static" \
  --extra-cflags="-I$PREFIX/include -O2 $ARCH_CFLAGS" \
  --extra-ldflags="-L$PREFIX/lib -static -static-libgcc -static-libstdc++" \
  --extra-libs="-lstdc++ -lpthread -lm -lws2_32 -liphlpapi -lbcrypt -lcrypt32 -lsecur32" \
  --enable-gpl \
  --enable-version3 \
  --enable-static \
  --disable-shared \
  --disable-autodetect \
  --disable-doc \
  --disable-ffplay \
  --disable-debug \
  \
  --enable-zlib \
  --enable-bzlib \
  --enable-schannel \
  \
  --enable-libx264 \
  --enable-libx265 \
  --enable-libvpx \
  --enable-libaom \
  --enable-libdav1d \
  --enable-libxvid \
  --enable-libtheora \
  --enable-libopenjpeg \
  --enable-libwebp \
  \
  --enable-libopus \
  --enable-libmp3lame \
  --enable-libvorbis \
  --enable-libspeex \
  --enable-libopencore-amrnb \
  --enable-libopencore-amrwb \
  --enable-libvo-amrwbenc \
  --enable-libsoxr \
  --enable-librubberband \
  \
  --enable-libzimg \
  --enable-libfreetype \
  --enable-libfribidi \
  --enable-libharfbuzz \
  --enable-libass \
  --enable-libvidstab \
  --enable-libvmaf \
  --enable-libgme \
  --enable-libsrt
else
PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" \
PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig" \
./configure \
  --arch="$FFMPEG_ARCH" \
  --extra-version="static-${VARIANT_LABEL}" \
  --target-os=linux \
  --cross-prefix="${CROSS_PREFIX}" \
  --pkg-config=pkg-config \
  --pkg-config-flags="--static" \
  --extra-cflags="-I$PREFIX/include -O2 $ARCH_CFLAGS" \
  --extra-ldflags="-L$PREFIX/lib -static" \
  --extra-libs="-lstdc++ -lpthread -lm -latomic" \
  --enable-gpl \
  --enable-version3 \
  --enable-static \
  --disable-shared \
  --disable-autodetect \
  --disable-doc \
  --disable-ffplay \
  --disable-debug \
  \
  --enable-zlib \
  --enable-bzlib \
  --enable-gnutls \
  \
  --enable-libx264 \
  --enable-libx265 \
  --enable-libvpx \
  --enable-libaom \
  --enable-libdav1d \
  --enable-libxvid \
  --enable-libtheora \
  --enable-libopenjpeg \
  --enable-libwebp \
  \
  --enable-libopus \
  --enable-libmp3lame \
  --enable-libvorbis \
  --enable-libspeex \
  --enable-libopencore-amrnb \
  --enable-libopencore-amrwb \
  --enable-libvo-amrwbenc \
  --enable-libsoxr \
  --enable-librubberband \
  \
  --enable-libzimg \
  --enable-libfreetype \
  --enable-libfribidi \
  --enable-libharfbuzz \
  --enable-libass \
  --enable-libzvbi \
  --enable-libvidstab \
  --enable-libvmaf \
  --enable-libgme \
  --enable-libsrt
fi

make -j"$NPROC"
ver "ffmpeg" "${FFMPEG_RELEASE}-${FFMPEG_GIT_VER}"

log "Build complete"

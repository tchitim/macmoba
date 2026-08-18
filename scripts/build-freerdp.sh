#!/bin/zsh
# Build the FreeRDP static libraries MacMoba's RDP tab links against, and drop
# the result in Vendor/FreeRDP/.
#
# Homebrew's freerdp formula is no use here: it is the X11 client build and
# drags in 21 dependencies (X11, ffmpeg, SDL3). We want only the protocol
# libraries — libfreerdp3, libfreerdp-client3, libwinpr3 — with every optional
# subsystem off, built static so the app has no dylib to ship and sign.
#
# usage: ./scripts/build-freerdp.sh [--clean]
#
# Requirements: cmake (the script fetches a standalone copy if missing) and
# OpenSSL 3. macOS ships no OpenSSL headers, so Homebrew's openssl@3 is used.

set -euo pipefail

FREERDP_VERSION=3.30.0
ROOT="${0:A:h}/.."
VENDOR="$ROOT/Vendor/FreeRDP"
WORK="$ROOT/.freerdp-build"
CMAKE_VERSION=4.4.2

if [[ "${1:-}" == "--clean" ]]; then
  rm -rf "$WORK" "$VENDOR"
  echo "Cleaned $WORK and $VENDOR"
  exit 0
fi

OPENSSL_ROOT="${OPENSSL_ROOT:-/opt/homebrew/opt/openssl@3}"
if [[ ! -d "$OPENSSL_ROOT" ]]; then
  echo "OpenSSL 3 not found at $OPENSSL_ROOT" >&2
  echo "Install it with: brew install openssl@3   (or set OPENSSL_ROOT)" >&2
  exit 1
fi

mkdir -p "$WORK"

# cmake: use the system one if present, otherwise fetch a standalone build into
# the work directory rather than installing anything system-wide.
if command -v cmake >/dev/null 2>&1; then
  CMAKE=cmake
else
  CMAKE="$WORK/cmake-$CMAKE_VERSION-macos-universal/CMake.app/Contents/bin/cmake"
  if [[ ! -x "$CMAKE" ]]; then
    echo "cmake not found — fetching a standalone copy into $WORK"
    curl -fsSL -o "$WORK/cmake.tar.gz" \
      "https://cmake.org/files/LatestRelease/cmake-$CMAKE_VERSION-macos-universal.tar.gz"
    tar xzf "$WORK/cmake.tar.gz" -C "$WORK"
    rm "$WORK/cmake.tar.gz"
  fi
fi

SRC="$WORK/FreeRDP-$FREERDP_VERSION"
if [[ ! -d "$SRC" ]]; then
  echo "Cloning FreeRDP $FREERDP_VERSION..."
  git clone --depth 1 --branch "$FREERDP_VERSION" \
    https://github.com/FreeRDP/FreeRDP.git "$SRC"
fi

# Note on audio: CHANNEL_RDPSND is ON with the AudioQueue backend
# (WITH_MACAUDIO). This flag read OFF for a while even though the vendored
# libraries had been built with it ON, so the script did not reproduce what
# shipped. AUDIN (microphone in) stays off — separate feature, and it would
# want a TCC prompt.
echo "Configuring..."
"$CMAKE" -S "$SRC" -B "$SRC/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$VENDOR" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
  -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF \
  -DWITH_X11=OFF -DWITH_SDL=OFF -DWITH_WAYLAND=OFF \
  -DWITH_FFMPEG=OFF -DWITH_SWSCALE=OFF -DWITH_CAIRO=OFF \
  -DWITH_SERVER=OFF -DWITH_SHADOW=OFF -DWITH_PROXY=OFF \
  -DWITH_CLIENT_SDL=OFF -DWITH_CLIENT_MAC=OFF \
  -DWITH_SAMPLE=OFF -DWITH_MANPAGES=OFF \
  -DWITH_FUSE=OFF -DWITH_PCSC=OFF -DWITH_PKCS11=OFF -DWITH_FIDO2=OFF \
  -DWITH_LIBUSB=OFF -DCHANNEL_URBDRC=OFF \
  -DCHANNEL_RDPSND=ON -DWITH_MACAUDIO=ON \
  -DCHANNEL_AUDIN=OFF -DCHANNEL_RDPECAM=OFF \
  -DWITH_JSON_DISABLED=ON \
  -DWITH_INTERNAL_MD4=ON -DWITH_INTERNAL_MD5=ON -DWITH_INTERNAL_RC4=ON \
  -DWITH_CUPS=OFF -DWITH_PULSE=OFF -DWITH_OSS=OFF -DWITH_ALSA=OFF \
  -DWITH_OPUS=OFF -DWITH_FAAD2=OFF -DWITH_FAAC=OFF \
  -DWITH_WEBVIEW=OFF -DWITH_KRB5=OFF -DWITH_AAD=OFF \
  -DOPENSSL_ROOT_DIR="$OPENSSL_ROOT"

echo "Building..."
"$CMAKE" --build "$SRC/build" --parallel "$(sysctl -n hw.ncpu)"

echo "Installing into $VENDOR..."
"$CMAKE" --install "$SRC/build"

# The channel helper libraries are built but not installed by FreeRDP's own
# install rules, and the client library references them at link time.
for extra in "$SRC"/build/channels/**/*.a(N); do
  cp "$extra" "$VENDOR/lib/"
done

echo
echo "Done. Vendored:"
ls -la "$VENDOR/lib"/*.a
echo
echo "Now run: swift build"

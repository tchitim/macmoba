#!/bin/zsh
# Builds mosh-client as a static, self-contained binary and vendors it into
# Vendor/Mosh/bin/mosh-client.
#
# We ship the real mosh C++ core rather than reimplementing SSP: the state
# synchronisation protocol and its AES-OCB crypto are the whole product, and a
# hand-written Swift version would be a new implementation of a security
# protocol with none of the scrutiny the original has had.
#
# Two things drive the awkward parts of this script:
#
#  * protobuf. mosh 1.4.0 uses the pre-Abseil C++ API, so protobuf must be
#    pinned to a 21.x release. Anything from 22 onwards pulls in Abseil and
#    fails to compile against this tree.
#  * Homebrew. The target Mac may not have it, so nothing may link against
#    /opt/homebrew. Everything is built from source into a private prefix.

set -euo pipefail

ROOT="${0:A:h:h}"
VENDOR="$ROOT/Vendor/Mosh"
WORK="${MOSH_BUILD_DIR:-/private/tmp/claude-501/-Users-timo-Downloads-macmoba-swift/24b99f23-0e97-45cc-a8bb-50adde81ccb2/scratchpad/mosh-build}"
PREFIX="$WORK/prefix"

PROTOBUF_VERSION="21.12"   # last series before Abseil became mandatory
MOSH_VERSION="1.4.0"
DEPLOYMENT_TARGET="13.0"

mkdir -p "$WORK" "$PREFIX"

# CMake: reuse the standalone copy the FreeRDP script fetches, or fetch one.
CMAKE="$(command -v cmake || true)"
if [[ -z "$CMAKE" ]]; then
  CMAKE_DIR="$WORK/cmake"
  if [[ ! -x "$CMAKE_DIR/CMake.app/Contents/bin/cmake" ]]; then
    echo "Fetching CMake..."
    mkdir -p "$CMAKE_DIR"
    curl -fsSL "https://github.com/Kitware/CMake/releases/download/v3.29.6/cmake-3.29.6-macos-universal.tar.gz" \
      | tar xz -C "$CMAKE_DIR" --strip-components 1
  fi
  CMAKE="$CMAKE_DIR/CMake.app/Contents/bin/cmake"
fi
echo "cmake: $CMAKE"

export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"

# ---------------------------------------------------------------- protobuf
if [[ ! -f "$PREFIX/lib/libprotobuf.a" ]]; then
  echo "Building protobuf $PROTOBUF_VERSION..."
  PB_SRC="$WORK/protobuf-$PROTOBUF_VERSION"
  if [[ ! -d "$PB_SRC" ]]; then
    curl -fsSL "https://github.com/protocolbuffers/protobuf/releases/download/v$PROTOBUF_VERSION/protobuf-cpp-3.$PROTOBUF_VERSION.tar.gz" \
      | tar xz -C "$WORK"
    mv "$WORK/protobuf-3.$PROTOBUF_VERSION" "$PB_SRC"
  fi
  "$CMAKE" -S "$PB_SRC" -B "$PB_SRC/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -Dprotobuf_BUILD_TESTS=OFF \
    -Dprotobuf_BUILD_SHARED_LIBS=OFF \
    -Dprotobuf_ABSL_PROVIDER=package
  "$CMAKE" --build "$PB_SRC/build" --parallel "$(sysctl -n hw.ncpu)"
  "$CMAKE" --install "$PB_SRC/build"
fi
echo "protobuf: $PREFIX/lib/libprotobuf.a"

# -------------------------------------------------------------------- mosh
MOSH_SRC="$WORK/mosh-$MOSH_VERSION"
if [[ ! -d "$MOSH_SRC" ]]; then
  echo "Fetching mosh $MOSH_VERSION..."
  # The release tarball ships a generated ./configure, which is why this does
  # not need autoconf/automake on the build machine.
  curl -fsSL "https://github.com/mobile-shell/mosh/releases/download/mosh-$MOSH_VERSION/mosh-$MOSH_VERSION.tar.gz" \
    | tar xz -C "$WORK"
fi

if [[ ! -x "$MOSH_SRC/src/frontend/mosh-client" ]]; then
  echo "Configuring mosh..."
  OPENSSL_ROOT="${OPENSSL_ROOT:-/opt/homebrew/opt/openssl@3}"
  cd "$MOSH_SRC"
  # Static where it matters: protobuf comes from our prefix, and the system
  # libraries used (curses, resolv, System) are present on every macOS.
  # protobuf_CFLAGS/LIBS instead of pkg-config: mosh's configure offers this
  # exact escape hatch, and it means the build machine does not need
  # pkg-config installed just to locate a library we built ourselves.
  # -lz is required because protobuf's static archive uses zlib.
  PROTOC="$PREFIX/bin/protoc" \
  protobuf_CFLAGS="-I$PREFIX/include" \
  protobuf_LIBS="-L$PREFIX/lib -lprotobuf -lz" \
  CPPFLAGS="-I$PREFIX/include -I$OPENSSL_ROOT/include" \
  LDFLAGS="-L$PREFIX/lib -L$OPENSSL_ROOT/lib" \
  ./configure \
    --prefix="$PREFIX" \
    --disable-silent-rules \
    --without-utempter \
    --disable-server \
    --enable-client
  echo "Building mosh-client..."
  make -j"$(sysctl -n hw.ncpu)" -C src/frontend mosh-client || make -j"$(sysctl -n hw.ncpu)"
fi

mkdir -p "$VENDOR/bin"
cp "$MOSH_SRC/src/frontend/mosh-client" "$VENDOR/bin/mosh-client"
strip -x "$VENDOR/bin/mosh-client" || true

echo
echo "Vendored: $VENDOR/bin/mosh-client"
echo "Linkage (must not mention /opt/homebrew):"
otool -L "$VENDOR/bin/mosh-client"

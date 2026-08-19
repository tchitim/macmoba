#!/bin/zsh
# Build MacMoba.app from the SwiftPM release build.
#
# Usage:
#   ./make-app.sh              → build + sign (Developer ID if installed, else ad-hoc)
#   ./make-app.sh --notarize   → also submit to Apple, staple, and verify
#
# Developer ID signing is picked up automatically once a
# "Developer ID Application: …" certificate exists in the login keychain.
# See README ("正式簽名 / 公證") for the one-time setup.
set -euo pipefail

cd "$(dirname "$0")"

NOTARIZE=0
ADHOC=0
DMG=0
case "${1:-}" in
  --notarize) NOTARIZE=1; DMG=1 ;;   # notarize the DMG that gets shipped
  --adhoc)    ADHOC=1 ;;             # skip Developer ID even if a cert is installed
  --dmg)      DMG=1 ;;               # build a distributable disk image
  --release)  NOTARIZE=1; DMG=1; RELEASE=1 ;;  # notarize, then publish to GitHub
esac
RELEASE="${RELEASE:-0}"
# Where the appcast is assembled. Keeping the PREVIOUS dmg here is what lets
# Sparkle compute a delta (a few KB instead of the whole 12 MB download).
RELEASE_DIR="${MACMOBA_RELEASE_DIR:-.release}"
GH_REPO="${MACMOBA_GH_REPO:-tchitim/macmoba}"
NOTARY_PROFILE="${MACMOBA_NOTARY_PROFILE:-macmoba}"

echo "Building release binary..."
swift build -c release

APP=MacMoba.app
BIN=.build/release/MacMoba
VERSION=1.73

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/MacMoba"

# SwiftPM resource bundles (SwiftTerm ships one): Bundle.module looks in
# Bundle.main.resourceURL first, which is Contents/Resources in an app bundle.
for bundle in .build/release/*.bundle(N); do
  cp -R "$bundle" "$APP/Contents/Resources/"
done

# Dynamic-library products (RoyalVNCKit declares one) are not statically linked,
# so the app has to carry them or dyld fails at launch with "Library not loaded".
# They go in Contents/Frameworks with an rpath pointing there, and each one is
# signed separately below — nested code must be signed before the outer bundle.
DYLIBS=(.build/release/*.dylib(N))
if (( ${#DYLIBS} )); then
  mkdir -p "$APP/Contents/Frameworks"
  for lib in $DYLIBS; do
    cp "$lib" "$APP/Contents/Frameworks/"
    # The build-time install name is a bare @rpath/<name>; keep it and add the
    # bundle-relative rpath the executable will search.
    install_name_tool -id "@rpath/${lib:t}" "$APP/Contents/Frameworks/${lib:t}" 2>/dev/null || true
  done
  install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$APP/Contents/MacOS/MacMoba" 2>/dev/null || true
  echo "Embedded ${#DYLIBS} dynamic librar$( (( ${#DYLIBS} == 1 )) && echo y || echo ies )."
fi

# Sparkle, for in-app updates. Copied whole: the framework carries its own
# XPC services and Updater.app, which are nested code and get signed below.
SPARKLE_FW="$(find .build/artifacts -name Sparkle.framework -maxdepth 6 -type d 2>/dev/null | head -1)"
if [[ -n "$SPARKLE_FW" ]]; then
  mkdir -p "$APP/Contents/Frameworks"
  cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/"
  echo "Embedded Sparkle.framework."
else
  echo "NOTE: Sparkle.framework not found — build once with 'swift build' first."
fi

# The control-socket CLI. Built as "macmoba-cli" (case-insensitive APFS would
# collide "macmoba" with "MacMoba" in .build/), shipped under its real name:
#   /Applications/MacMoba.app/Contents/Resources/bin/macmoba
mkdir -p "$APP/Contents/Resources/bin"
cp .build/release/macmoba-cli "$APP/Contents/Resources/bin/macmoba"

if [[ -f AppIcon.icns ]]; then
  cp AppIcon.icns "$APP/Contents/Resources/"
fi

# mosh-client: the real mosh C++ core, shipped as its own executable and run as
# a child process. It is GPLv3, so it stays a separate program rather than being
# linked in — and the licence and a written offer for the source ship with it,
# which GPLv3 section 6 requires when distributing a binary.
if [[ -x Vendor/Mosh/bin/mosh-client ]]; then
  cp Vendor/Mosh/bin/mosh-client "$APP/Contents/Resources/"
  for doc in Vendor/Mosh/COPYING Vendor/Mosh/MOSH-SOURCE-OFFER.txt; do
    [[ -f "$doc" ]] && cp "$doc" "$APP/Contents/Resources/"
  done
  echo "Embedded mosh-client (GPLv3, with licence and source offer)."
else
  echo "NOTE: Vendor/Mosh/bin/mosh-client missing — Mosh sessions will not run."
  echo "      Build it with ./scripts/build-mosh.sh"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>MacMoba</string>
    <key>CFBundleIdentifier</key>
    <string>dev.macmoba.MacMoba</string>
    <key>CFBundleName</key>
    <string>MacMoba</string>
    <key>CFBundleDisplayName</key>
    <string>MacMoba</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>MacMoba</string>
    <!-- Lets a .rdp file be opened from the Finder. "Viewer" rather than
         "Editor": MacMoba connects with these, it never writes them. -->
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Remote Desktop Connection</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>com.microsoft.rdp</string>
            </array>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>rdp</string>
            </array>
        </dict>
    </array>
    <!-- In-app updates (Sparkle). The private EdDSA key lives in the login
         keychain and signs each DMG at release time; this public half is what
         the installed app checks the download against, on top of the Developer
         ID signature. -->
    <key>SUFeedURL</key>
    <string>https://github.com/tchitim/macmoba/releases/latest/download/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>BUsDV4a3zS+5qNiEPCv5XRBpGXFSlbJIdTm5xMvyVlU=</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>SUScheduledCheckInterval</key>
    <integer>86400</integer>
    <!-- Ask before downloading: an update swaps the app under a live session. -->
    <key>SUAutomaticallyUpdate</key>
    <false/>
    <!-- Quick-connect URL schemes: clicking ssh://user@host (in a browser,
         Notes, wherever) opens a session. Viewer role — we connect, not own. -->
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>dev.macmoba.connect</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>ssh</string>
                <string>sftp</string>
                <string>mosh</string>
                <string>telnet</string>
                <string>rdp</string>
                <string>vnc</string>
            </array>
        </dict>
    </array>
    <!-- Custom drag type must be declared or the pasteboard drops it,
         which breaks in-panel SFTP move drags. -->
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>dev.macmoba.sftp-item</string>
            <key>UTTypeDescription</key>
            <string>MacMoba SFTP item</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.data</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict/>
        </dict>
    </array>
</dict>
</plist>
PLIST

# --- Signing -----------------------------------------------------------------
# Prefer a real Developer ID identity; fall back to ad-hoc for local use.
IDENTITY=""
if (( ! ADHOC )); then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep 'Developer ID Application' | head -1 | sed -E 's/.*"(.+)"/\1/')"
fi

# Embedded dylibs are nested code: they must each be signed, and signed BEFORE
# the app bundle, or the outer signature seals an unsigned library and
# --verify --strict fails.
sign_nested() {
  local identity="$1"
  for lib in "$APP"/Contents/Frameworks/*.dylib(N); do
    if [[ "$identity" == "-" ]]; then
      codesign --force --sign - "$lib"
    else
      codesign --force --options runtime --timestamp --sign "$identity" "$lib"
    fi
  done
  # mosh-client is a second Mach-O binary in the bundle, so it is nested code
  # too: unsigned, the outer signature seals it and --verify --strict fails,
  # and notarisation rejects the whole app.
  # Sparkle's nested code, innermost first: XPC services and the updater apps
  # are separate bundles, and an unsigned one inside a signed framework fails
  # --verify --strict and notarisation.
  local sparkle="$APP/Contents/Frameworks/Sparkle.framework"
  if [[ -d "$sparkle" ]]; then
    for nested in \
      "$sparkle/Versions/B/XPCServices/Downloader.xpc" \
      "$sparkle/Versions/B/XPCServices/Installer.xpc" \
      "$sparkle/Versions/B/Updater.app" \
      "$sparkle/Versions/B/Autoupdate" \
      "$sparkle"; do
      [[ -e "$nested" ]] || continue
      if [[ "$identity" == "-" ]]; then
        codesign --force --sign - "$nested"
      else
        codesign --force --options runtime --timestamp --sign "$identity" "$nested"
      fi
    done
  fi
  for cli in "$APP"/Contents/Resources/bin/*(N); do
    if [[ "$identity" == "-" ]]; then
      codesign --force --sign - "$cli"
    else
      codesign --force --options runtime --timestamp --sign "$identity" "$cli"
    fi
  done
  local helper="$APP/Contents/Resources/mosh-client"
  if [[ -f "$helper" ]]; then
    if [[ "$identity" == "-" ]]; then
      codesign --force --sign - "$helper"
    else
      codesign --force --options runtime --timestamp --sign "$identity" "$helper"
    fi
  fi
}

if [[ -n "$IDENTITY" ]]; then
  echo "Signing with: $IDENTITY"
  # SwiftPM resource bundles hold no Mach-O code (just resources such as
  # PrivacyInfo.xcprivacy) and have no Info.plist, so codesign rejects them as
  # bundles. They are sealed as resources by the app signature instead.
  # Notarization requires hardened runtime + a secure timestamp.
  sign_nested "$IDENTITY"
  codesign --force --options runtime --timestamp \
    --entitlements MacMoba.entitlements --sign "$IDENTITY" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
else
  echo "No Developer ID certificate found — ad-hoc signing (this Mac only)."
  echo "To ship: create a 'Developer ID Application' cert, download it, then re-run."
  sign_nested "-"
  codesign --force --sign - "$APP"
  if (( NOTARIZE )); then
    echo "Cannot notarize an ad-hoc signed app. Aborting." >&2
    exit 1
  fi
fi

# --- Notarization (app first) --------------------------------------------------
# The app is notarized and stapled BEFORE the disk image is built, so the copy
# users drag out carries its own ticket and passes Gatekeeper even offline.
# Stapling only the DMG leaves the extracted app relying on an online check.
if (( NOTARIZE )); then
  echo "Notarizing the app (profile: $NOTARY_PROFILE)..."
  APP_ZIP="$(mktemp -d)/MacMoba.zip"
  ditto -c -k --keepParent "$APP" "$APP_ZIP"
  xcrun notarytool submit "$APP_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  rm -f "$APP_ZIP"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
fi

# --- Disk image ---------------------------------------------------------------
DMG_FILE="MacMoba-${VERSION}.dmg"
if (( DMG )); then
  echo "Building $DMG_FILE ..."
  STAGE="$(mktemp -d)/MacMoba"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"   # drag-to-install layout
  rm -f "$DMG_FILE"
  hdiutil create -volname "MacMoba $VERSION" -srcfolder "$STAGE" \
    -ov -format UDZO "$DMG_FILE" >/dev/null
  rm -rf "$STAGE"
  if [[ -n "$IDENTITY" ]]; then
    codesign --force --timestamp --sign "$IDENTITY" "$DMG_FILE"
    codesign --verify --verbose=2 "$DMG_FILE"
  fi
  echo "Disk image: $DMG_FILE"
fi

# --- Notarization (the disk image itself) --------------------------------------
if (( NOTARIZE )); then
  echo "Notarizing $DMG_FILE ..."
  xcrun notarytool submit "$DMG_FILE" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG_FILE"
  xcrun stapler validate "$DMG_FILE"
  spctl --assess --type execute --verbose=2 "$APP"
  echo "Notarized and stapled — runs on any Mac without warnings."
fi

# --- Release: sign the appcast and publish to GitHub ---------------------------
# The appcast is what installed copies check. Every enclosure in it points at
# THIS tag's assets, so everything in $RELEASE_DIR is uploaded to this release —
# including the previous dmg the delta was computed against.
if (( RELEASE )); then
  TAG="v${VERSION}"
  command -v gh >/dev/null || { echo "ERROR: gh CLI not installed"; exit 1; }

  if gh release view "$TAG" --repo "$GH_REPO" >/dev/null 2>&1; then
    echo "ERROR: release $TAG already exists on $GH_REPO."
    echo "       Bump VERSION in this script, or delete the release first."
    exit 1
  fi
  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    echo "ERROR: working tree has uncommitted changes — commit them first so the"
    echo "       release tag names the code it was built from."
    exit 1
  fi
  git push origin HEAD >/dev/null 2>&1 || true

  GENERATE_APPCAST="$(find .build/artifacts -name generate_appcast -type f 2>/dev/null | head -1)"
  [[ -n "$GENERATE_APPCAST" ]] || { echo "ERROR: generate_appcast missing (build once first)"; exit 1; }

  mkdir -p "$RELEASE_DIR"
  cp "$DMG_FILE" "$RELEASE_DIR/"
  # Only the last few builds are worth keeping: deltas are computed against
  # them, and every one of them gets uploaded to this release.
  # (N) is zsh's null glob: without it an empty match aborts the script.
  ls -t "$RELEASE_DIR"/MacMoba-*.dmg(N) | tail -n +3 | xargs -r rm -f
  rm -f "$RELEASE_DIR"/appcast.xml(N) "$RELEASE_DIR"/*.delta(N)

  echo "Signing appcast (EdDSA key from the login keychain) ..."
  "$GENERATE_APPCAST" \
    --download-url-prefix "https://github.com/${GH_REPO}/releases/download/${TAG}/" \
    "$RELEASE_DIR" >/dev/null

  echo "Publishing $TAG to $GH_REPO ..."
  gh release create "$TAG" "$RELEASE_DIR"/*(N) \
    --repo "$GH_REPO" \
    --title "MacMoba ${VERSION}" \
    --notes "MacMoba ${VERSION}

安裝:下載 \`MacMoba-${VERSION}.dmg\`,拖進「應用程式」。已 Developer ID 簽名 + Apple 公證。
需求:macOS 13+、Apple Silicon。

已安裝的版本會透過 App 內更新自動取得這一版。"

  # The installed apps read exactly this URL — a release that does not serve it
  # is a silent no-op, so check rather than assume.
  FEED="https://github.com/${GH_REPO}/releases/latest/download/appcast.xml"
  if curl -sfL "$FEED" | grep -q "<sparkle:version>${VERSION}</sparkle:version>"; then
    echo "Feed serves ${VERSION}: $FEED"
  else
    echo "WARNING: $FEED does not offer ${VERSION} yet — check the release assets."
  fi
fi

echo "Done: $APP"
echo "Try:  open $APP        (drag to /Applications if you like it)"

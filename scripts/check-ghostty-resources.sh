#!/bin/zsh
# Does GhosttyTerminal find its resources inside a packaged .app, on a machine
# that did not build it?
#
# The bug this guards against crashed the app on every Mac except this one:
# SwiftPM's generated `Bundle.module` looks only at the .app ROOT (where
# codesign forbids putting anything) and at the absolute .build path of the
# build machine — never at Contents/Resources, where the bundle actually goes.
# On the build machine the second candidate exists, so the fault is invisible
# exactly where it would be caught.
#
# So this builds a fake .app in a temp dir, far from any .build, and runs the
# probe inside it.
set -e
cd ${0:A:h}/..
swift build -c release --product ghostty-resource-probe >/dev/null

app=$(mktemp -d)/Probe.app
mkdir -p $app/Contents/MacOS $app/Contents/Resources
cp .build/release/ghostty-resource-probe $app/Contents/MacOS/probe
cp -R .build/release/GhosttyKit_GhosttyTerminal.bundle $app/Contents/Resources/
cat > $app/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>probe</string>
<key>CFBundleIdentifier</key><string>dev.macmoba.probe</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST

# Hide the build-directory copy for the duration. Without this the check is
# worthless ON THE BUILD MACHINE: the old `Bundle.module` accessor would find
# that copy through its baked-in absolute path and pass, which is precisely how
# the bug shipped in the first place.
built=.build/release/GhosttyKit_GhosttyTerminal.bundle
hidden=$built.hidden-for-check
cleanup() { [[ -d $hidden ]] && mv $hidden $built; }
trap cleanup EXIT INT TERM
mv $built $hidden

echo "probe app: $app"
if $app/Contents/MacOS/probe; then
  echo "PASS — resources resolve from Contents/Resources"
else
  echo "FAIL — the packaged app would crash on another Mac"
  exit 1
fi

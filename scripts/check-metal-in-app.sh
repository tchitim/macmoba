#!/bin/zsh
# Does the Metal renderer actually initialise inside a packaged .app?
#
# Asked because the same class of bug already bit the libghostty spike: a
# SwiftPM resource bundle that resolves on the build machine and nowhere else.
# SwiftTerm's shaders live in exactly such a bundle, and its renderer probes
# for it by hand precisely because SwiftPM's generated accessor looks in the
# wrong places (see MetalTerminalRenderer.candidateBundles). This checks that
# the workaround holds where it matters: bundle in Contents/Resources, and no
# .build directory to fall back through.
set -e
cd ${0:A:h}/..
swift build -c release --product terminal-render-bench >/dev/null

app=$(mktemp -d)/Metal.app
mkdir -p $app/Contents/MacOS $app/Contents/Resources
cp .build/release/terminal-render-bench $app/Contents/MacOS/bench
cp -R .build/release/SwiftTerm_SwiftTerm.bundle $app/Contents/Resources/
cat > $app/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>bench</string>
<key>CFBundleIdentifier</key><string>dev.macmoba.metalbench</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST

built=.build/release/SwiftTerm_SwiftTerm.bundle
hidden=$built.hidden-for-check
cleanup() { [[ -d $hidden ]] && mv $hidden $built; }
trap cleanup EXIT INT TERM
mv $built $hidden

echo "running inside $app with the build-dir bundle hidden ..."
out=$($app/Contents/MacOS/bench 2>&1)
echo $out
if echo $out | grep -q "unavailable"; then
  echo "FAIL — Metal did not initialise in a packaged app"
  exit 1
fi
echo "PASS — Metal initialises from Contents/Resources"

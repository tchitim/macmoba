#!/bin/zsh
# Build libghostty-vt and run the parsing benchmark against it.
#
# There is no tagged libghostty release yet, so this pins nothing: it builds
# whatever ghostty main is today. Record the commit with any number you quote.
set -e
here=${0:A:h}
work=${LIBGHOSTTY_WORK:-/tmp/libghostty-spike}

command -v zig >/dev/null || { echo "needs zig 0.16 (brew install zig)"; exit 1; }

[[ -d $work/ghostty ]] || git clone --depth 1 https://github.com/ghostty-org/ghostty.git $work/ghostty
cd $work/ghostty
echo "ghostty commit: $(git rev-parse --short HEAD)"
zig build -Demit-lib-vt=true -Doptimize=ReleaseFast --prefix ./out

cd $here
for prog in ghostty-verify ghostty-bench; do
  clang -O2 -I$work/ghostty/out/include $prog.c \
        $work/ghostty/out/lib/libghostty-vt.a -o $work/$prog
done
echo "--- correctness first: a number from a parser that dropped the input is worthless"
$work/ghostty-verify
echo "--- throughput"
$work/ghostty-bench

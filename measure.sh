#!/bin/zsh
# Measure the numbers STATUS.md holds budgets for, on a RELEASE build.
#
# Borrowed discipline (KKTerm's PERFORMANCE.md does exactly this): a budget
# that is a number turns a regression into an event; an adjective lets it
# drift. Dev builds are not measured — they answer a different question.
#
#   ./make-app.sh && ./measure.sh                 # cold launch + control RTT
#   MEASURE_SESSION="MacMini" ./measure.sh        # + open-to-connected for one
#                                                 #   saved session (includes
#                                                 #   network and auth — label
#                                                 #   it as such when recording)
#
# Prints one line per metric. Record results and the machine in STATUS.md
# next to the budgets. This QUITS any running MacMoba — do not run it while
# real sessions are open.

set -e
zmodload zsh/datetime
zmodload zsh/mathfunc

APP="${MEASURE_APP:-MacMoba.app}"
CLI="$APP/Contents/Resources/bin/macmoba"
[[ -x "$CLI" ]] || { echo "no CLI inside $APP — run ./make-app.sh first" >&2; exit 1 }

now_ms() { print $(( int(EPOCHREALTIME * 1000) )) }

# --- cold launch: `open` until the control socket answers ------------------
# The end mark is deliberately "the app can be talked to", not "a window is
# on screen": it is measurable without accessibility permissions, and it is
# the moment automation (and the person typing ⌘K) can actually start.
pkill -x MacMoba 2>/dev/null || true
sleep 2
t0=$(now_ms)
open -a "$PWD/$APP"
until "$CLI" ping >/dev/null 2>&1; do
  sleep 0.02
  (( $(now_ms) - t0 > 15000 )) && { echo "cold-launch: TIMEOUT (15s)" >&2; exit 1 }
done
echo "cold-launch-to-control-ready: $(( $(now_ms) - t0 )) ms"

# --- control round-trip: 20 pings, average --------------------------------
t0=$(now_ms)
for i in {1..20}; do "$CLI" ping >/dev/null; done
echo "control-round-trip-avg: $(( ($(now_ms) - t0) / 20 )) ms"

# --- optional: open a saved session until it reports connected -------------
# Includes DNS, TCP, SSH auth — everything. Useful as a trend on one machine
# against one host, meaningless as an absolute.
if [[ -n "$MEASURE_SESSION" ]]; then
  before=$("$CLI" list-tabs | /usr/bin/python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
  t0=$(now_ms)
  "$CLI" open "$MEASURE_SESSION" >/dev/null
  until "$CLI" list-tabs | /usr/bin/python3 -c '
import json,sys
tabs=json.load(sys.stdin)
sys.exit(0 if len(tabs)>'"$before"' and tabs[-1]["state"]=="connected" else 1)
' 2>/dev/null; do
    sleep 0.05
    (( $(now_ms) - t0 > 30000 )) && { echo "open-to-connected: TIMEOUT (30s)" >&2; exit 1 }
  done
  echo "open-to-connected ($MEASURE_SESSION, incl. network+auth): $(( $(now_ms) - t0 )) ms"
fi

# --- idle memory: physical footprint after settling -------------------------
sleep 3
footprint=$(ps -o rss= -p "$(pgrep -x MacMoba)" | awk '{printf "%.0f", $1/1024}')
echo "idle-memory-rss: ${footprint} MiB"

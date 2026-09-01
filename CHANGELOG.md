# Changelog

Newest first. Each release published to GitHub takes its notes from the section
matching its version, and `make-app.sh` refuses to publish a version that has no
entry here — release notes that can be forgotten are release notes nobody writes.

## 2.19

**Web tab: keep digging at the self-signed certificate refusal.**
A pinned certificate is now handed back with its faults formally excused
(`SecTrustSetExceptions`), because returning a credential built on a trust that
still evaluates as bad is the documented way to have it refused twice. The
diagnostics also record *which* URL failed — a refusal for a host that never
produced a challenge is a different problem from one for the host just accepted.

網頁分頁:繼續追自簽憑證被拒的問題。已釘選的憑證現在會正式標記「使用者已接受這些瑕疵」再交回去;
診斷也會記下**是哪一個網址**失敗——沒出現過憑證詢問的主機失敗,跟剛剛才接受的主機失敗,是兩回事。

## 2.18

**Log what the certificate challenge actually contains.**
Two releases guessed wrong, so every decision is now recorded: host, whether the
system trusted it, the offered and stored fingerprints, the action taken and the
answer given. The alert also brings the app forward first — a prompt nobody sees
is indistinguishable from a broken feature.

    log show --predicate 'subsystem == "dev.macmoba.tls"' --last 10m --info

## 2.17

**Answer the certificate challenge before asking, not after.**
Trusting a certificate did nothing in 2.16. A WKWebView trust challenge has to be
answered on the spot: measured against a real self-signed server, answering even
0.2s late leaves the navigation dead. So the attempt is declined immediately, the
user is asked afterwards, and on acceptance the fingerprint is pinned and the page
reloaded.

## 2.16

**Web tabs can reach servers whose certificate the Mac won't verify.**
Internal consoles are almost always self-signed or behind a private CA, and WebKit
refused them outright. Rather than ignoring TLS errors, the certificate is now
pinned per host the way SSH host keys and RDP certificates already are: a good
certificate never prompts, an unknown one shows its fingerprint once, and a pinned
one that later changes always asks again. Revocable from Trusted Hosts.

## 2.15

**Repaint only the dirty rows while dragging a selection.**
Copying was never the slow part — extracting a selection takes about 4ms whether
it covers a thousand lines or ten thousand. The stutter was SwiftTerm repainting
the whole view on every mouse-move of a drag: 7.2ms at 1200×800, 22.4ms at
2560×1440. SwiftTerm's Metal renderer marks only the changed rows, so it is now
available as **Settings → Terminal → GPU rendering** (off by default, applies live).

## 2.14

**Ten thousand lines of scrollback, not five hundred.**
SwiftTerm's 500-line default had never been changed. That is a terminal-widget
default, not a session-manager one — a few seconds of a build log. Now 10,000 by
default and adjustable from 500 to 100,000. The buffer grows with output rather
than being allocated up front, so idle panes cost nothing extra.

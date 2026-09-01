# Changelog

Newest first. Each release published to GitHub takes its notes from the section
matching its version, and `make-app.sh` refuses to publish a version that has no
entry here — release notes that can be forgotten are release notes nobody writes.

## 2.21

**Local terminals can be split, and can share a tab with anything else.**
The local shell was the one tab kind left out of the heterogeneous-split work:
it parked a never-connected SSH pane in the tree and drew itself around it, so
`canSplit` had to claim the tab had no tree at all. It is now an ordinary leaf,
which means Split Right/Down works on it, it can sit beside an SSH pane or a
remote desktop, it survives Break Apart into Tabs, and the arrangement is
restored on the next launch. The split menu gained **New Local Terminal**.

本機終端機現在可以分割,也可以跟其他任何連線共用同一個分頁。它原本是唯一沒有納入異質分割的分頁類型——
在樹裡塞一個永遠不會連線的 SSH pane,再繞過它自己畫,所以 `canSplit` 只能宣稱這個分頁根本沒有樹。
現在它就是一個普通的葉節點:可以分割、可以跟 SSH 或遠端桌面並排、解散分割後仍然正常,版面也會在下次啟動還原。
分割選單新增 **New Local Terminal**。

## 2.20

**Web tabs can finally load a self-signed internal console.**
The certificate pin was working all along — the fingerprint matched, the
credential was accepted immediately, and the load still failed with -1202. The
cause was App Transport Security, and the part that is not obvious is that an
ATS refusal **cannot be overridden from the authentication challenge**: the
prompt appears, trusting works, the pin is stored, and the page fails anyway.
Web-view content is now exempt from ATS (`NSAllowsArbitraryLoadsInWebContent`),
which leaves the app's own network calls under ATS and leaves the per-host
certificate pin — the thing actually protecting these tabs — fully in force.

網頁分頁終於能開自簽憑證的內部主控台。憑證釘選一直都是正常的——指紋相符、當場接受、卻還是 -1202。
真正的原因是 App Transport Security,而不明顯的地方在於:**ATS 的拒絕無法從憑證詢問那裡覆蓋**——
對話框會跳、按信任有效、指紋也存了,頁面照樣失敗。現在只讓網頁內容豁免 ATS,
App 自己的網路請求仍受 ATS 保護,而真正在保護這些分頁的每主機憑證釘選完全不受影響。

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

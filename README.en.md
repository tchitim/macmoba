# MacMoba

**English** · [繁體中文](README.md)

A native remote-connection workstation for macOS — SSH, Mosh, Telnet, Rlogin, SFTP/FTP, VNC, RDP, serial ports, web pages and local shells, all in one window.

Written in Swift and SwiftUI, no Electron. Passwords live in a local encrypted vault, and a bundled CLI lets scripts and AI agents drive the app in return.

**[📖 Getting started](docs/getting-started.en.md)** · **[📋 Changelog](CHANGELOG.md)** · **[⬇️ Download the latest release](../../releases/latest)**

---

## Features

**Connections**
- SSH (chained `ssh -J` jump hosts, gateway failover), Mosh (survives losing the network), Telnet, Rlogin, serial (RS-232)
- VNC, RDP (NLA/CredSSP, multi-display, clipboard with files), FTP/FTPS
- **Remote desktop input capture**: click in and the keyboard and mouse belong to the remote machine (⌃⌥ to let go). Physical keys are forwarded, so composition is the remote input method's job; ⌥⌘V / ⌥⌘C carry text the VNC protocol cannot
- Web tabs, optionally routed through a chosen SSH session's SOCKS tunnel to reach an internal page; **self-signed and private-CA certificates** (an OpenShift console, a Cockpit, a switch's admin UI) can be pinned after you have seen the fingerprint, and are queried again if they ever change
- Local shell tabs

**Organising**
- Nested folders, colour tags, labels, notes, sidebar search
- Shared credential objects, inherited up the folder path
- Password-manager references (`op://`, `cmd:…`) — read at connect time, never stored
- Session templates with replacement tokens; automation (run on connect, expect/send)

**Terminal**
- **Mixed split panes**: a shell, a remote desktop and a web page side by side in one tab; merge them, break them apart into tabs, and **the arrangement is restored on next launch**
- MultiExec broadcast input, macros, session logging, scrollback search
- **10,000 lines** of scrollback by default (adjustable from 500 to 100,000); optional **GPU rendering**, which is noticeably smoother when dragging a selection across a large window
- SFTP panel (Quick Look, chmod, hidden files, drag to upload)
- ZMODEM transfers both ways (`rz`/`sz`), paste a screenshot to upload it
- X11 forwarding (over a remote forward; needs XQuartz)

**Tools**
- SSH key generator (ed25519 / ECDSA)
- Trusted Hosts: review and revoke pinned SSH host keys, RDP and web certificates
- Network tools: Wake-on-LAN, port scan, DNS lookup
- Bonjour discovery, reachability monitoring, remote resource monitor
- Import from `~/.ssh/config`, PuTTY `.reg`, RDCMan `.rdg`

**Automation**
- `macmoba` CLI over a Unix control socket (list-tabs / open / open-url / send / read-screen / notify)
- AI agent hooks (Claude Code, Codex): the tab lights up and a notification arrives when an agent finishes or needs approval

---

## Install

Download the DMG from [Releases](../../releases/latest). Signed with a Developer ID and notarised by Apple.

Requires **macOS 14+** on **Apple Silicon**. See the [getting-started guide](docs/getting-started.en.md).

---

## Building from source

RDP needs the bundled FreeRDP built first (about 14 MB, not in version control):

```bash
./scripts/build-freerdp.sh   # once, produces Vendor/FreeRDP
./scripts/build-mosh.sh      # needed for Mosh sessions (GPLv3, separate binary)
```

```bash
swift build -c release      # build
swift test                  # test (some integration tests need TestSupport/ssh-server.js)
./make-app.sh               # package MacMoba.app (Developer ID if a certificate is installed)
./make-app.sh --notarize    # package, notarise, and produce a DMG
```

Releasing (build → notarise → sign the appcast → create the GitHub release → verify the feed):

```bash
# bump VERSION in make-app.sh, commit, then:
./make-app.sh --release
```

The suite is about 763 tests. Integration tests that need an external service skip themselves when it is not running:

```bash
cd TestSupport && npm install && node ssh-server.js   # local SSH/SFTP test server
```

---

## Security

- Vault: scrypt (N=16384, r=8, p=1) + AES-256-GCM; the master password is never written to disk
- Password-manager references resolve to plaintext at connect time only, and are discarded afterwards — never written to the vault
- Host key pinning (known_hosts). A **changed** key is always warned about on its own and is never covered by a trust burst
- Control socket is 0600 with a token reissued on every launch
- Session logs are plaintext: anything on screen goes in (file 0600, folder 0700)

## Known limitations

- arm64 only (the bundled FreeRDP is a static library built for Apple Silicon)
- No RSA keys, ssh-agent or keyboard-interactive (2FA/OTP) — all upstream SwiftNIO SSH limitations
- X11 forwarding needs XQuartz with TCP listening enabled

---

## Licence

Bundles [mosh](https://mosh.org/) (GPLv3), shipped as a separate executable with its licence and a written offer for the source inside the app.

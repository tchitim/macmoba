# Getting started

**English** · [繁體中文](getting-started.md)

MacMoba is a native remote-connection workstation for macOS — the core of what MobaXterm and Royal TSX do, on a Mac. SSH, Mosh, Telnet, Rlogin, SFTP/FTP, VNC, RDP, serial ports and web pages share one window, passwords live in a local encrypted vault, and a `macmoba` CLI lets scripts and AI agents drive the app in return.

---

## Install

**Download the DMG (recommended)**

Get the latest `MacMoba-x.y.dmg` from [Releases](../../releases/latest), open it, and drag `MacMoba.app` to Applications.

The app is **signed with a Developer ID and notarised by Apple**, so first launch does not warn about an unidentified developer. If macOS still asks, choose Open.

**Requirements**

| | |
|---|---|
| macOS | 14 Sonoma or later |
| Processor | **Apple Silicon (arm64)** |
| Disk | about 40 MB |

> ⚠️ arm64 only. The bundled FreeRDP static library is built for Apple Silicon, so an Intel Mac cannot run it.

---

## First launch

You will be asked to **create the vault**:

1. Choose a **master password**. It protects every session and password you save, with scrypt + AES-256-GCM — **there is no recovery if you forget it**.
2. If the Mac has Touch ID, tick "Remember in Keychain for Touch ID unlock" to use your fingerprint from then on.
3. Once unlocked you get the main window: sessions on the left, tabs on the right.

The vault file is `~/Library/Application Support/MacMoba/vault.json`, mode 0600.

---

## Your first connection

1. **+** in the sidebar's **Sessions** header → **New Session…**
2. Fill in name, host and port under **General**; username and password (or a private key file) under **Login**
3. **⌘S** to save, then **double-click** the session to connect

Connecting to a host for the first time asks you to confirm its host key. If you are opening a whole folder at once, tick **"Also trust other new hosts for the next 2 minutes"** and the rest of that batch will not ask again — but a host whose key has **changed** always warns on its own, because that is what a man-in-the-middle looks like.

### Folders and inheritance

Sessions go in nested folders, written with slashes:

```
Production/Linux
Production/Windows
```

Right-click a folder → **New Subfolder…** creates one directly. A folder's **Group Credential** supplies a shared login, and subfolders **inherit up the path** (nearest ancestor wins), so one credential can cover a whole project.

### Password managers

Instead of a literal password, the field takes a **reference**, read at connect time and **never stored in the vault**:

```
op://Personal/my-server/password                      # 1Password CLI
cmd:security find-generic-password -w -s my-server     # Keychain, pass, keepassxc-cli…
```

1Password needs the `op` CLI installed, with "Integrate with 1Password CLI" enabled in Settings → Developer.

### Session templates

**A session with everything filled in except the host** — so that adding another machine is not retyping the same eight fields.

Say a batch of VMs all use port 22, root, the same jump host, run `cd /opt && ls` on connect, and are tagged `vm` in green. Save that as a template, and adding the sixth machine becomes:

**+ in the Sessions header → From Template → pick it** → the editor opens with **every field filled in and only the host empty**. Type the address, ⌘S, done.

Templates live in **Library (⌥⌘L) → Templates** and deliberately **do not appear in the session list** — a template is a mould, not a connection.

**The tokens are the point.** A template's run-on-connect commands can carry variables, expanded at send time with that machine's own values:

```bash
echo "signed in to %username%@%host%:%port%"
tmux new -A -s %name%
```

Available: `%host%` `%port%` `%username%` (or `%user%`) `%name%` `%group%` `%domain%` `%webURL%`. Case-insensitive; an unknown token is left exactly as written rather than breaking. So **one template covers a fleet**, instead of a script per machine.

> If all you want to share is a **login**, a group credential is more direct (right-click a folder → Group Credential, inherited by subfolders). A template is for a whole set of settings; a group credential is for one set of credentials.

---

## SSH tunnels (port forwarding)

The sidebar's **Tunnels** section, **+** on the right. Each tunnel has its own switch, and **it is independent of any tab**: a tunnel opens its own connection, so the machine's terminal does not have to be open.

**Via session** only lists SSH and Mosh sessions: a tunnel is an SSH channel, which a remote desktop or a serial line cannot carry.

### Three directions

| Direction | What it means | Typical use |
|---|---|---|
| **Local (-L)** | A port here → a target the server can reach | Point a local tool at an internal database |
| **Remote (-R)** | A port on the server → a target this Mac can reach | Show a colleague the service you are running locally |
| **Dynamic (-D)** | A SOCKS5 proxy here | Send a browser, or anything that speaks SOCKS, out through the remote network |

### Example: a local tool against an internal database

The database is at `192.0.2.20:5432` and only the bastion can reach it.

- Direction: **Local (-L)**
- Via session: the bastion
- Local port: `15432`
- Target host: `192.0.2.20` (**as the server sees it**)
- Target port: `5432`

Turn the switch on, and `127.0.0.1:15432` on this Mac is that database.

### Example: a SOCKS proxy for internal pages

- Direction: **Dynamic (-D)**, Local port: `1080`, Via session: the bastion

Point your browser's SOCKS5 setting at `127.0.0.1:1080`.

**MacMoba's web tabs can do this for you**: create a Web session and choose an SSH session under **Tunnel through**, and that tab's traffic goes through its SOCKS tunnel — no tunnel to set up, no browser settings to change.

> ⚠️ **macOS does something that misleads people here**: it bypasses the proxy entirely for **loopback and for addresses on your own subnet**. So some addresses connect directly however carefully the tunnel is configured. MacMoba says so plainly — the toolbar turns orange and reads `not via bastion`, rather than showing a "via the bastion" badge that is not true.


## Setting up the CLI

The app bundles a `macmoba` binary so a terminal, a script or an AI agent on a remote host can drive MacMoba. Link it somewhere on your PATH:

```bash
ln -s /Applications/MacMoba.app/Contents/Resources/bin/macmoba /usr/local/bin/macmoba
```

Common commands:

```bash
macmoba list-tabs                          # every tab and its state
macmoba open "web-server"                  # open a saved session
macmoba open-url http://192.0.2.5:3000 --via "Jumphost"   # web tab through an SSH session's SOCKS tunnel
macmoba send --tab 0 'uptime\n'            # type into a tab (\n = Return)
macmoba read-screen --tab 0 --lines 30     # read the screen back
macmoba notify --title "deploy finished"   # raise a notification
```

The control channel is `~/Library/Application Support/MacMoba/control.sock` (0600), with a token reissued on every launch, reachable only by this user on this machine.

### AI agent integration

If you run Claude Code in a MacMoba local shell tab:

```bash
macmoba hooks install claude    # merged into ~/.claude/settings.json (backed up first)
macmoba hooks install codex     # prints a config.toml snippet for you to paste
```

After that, a tab lights up with a blue dot when its agent finishes or needs approval; when the app is in the background you get a system notification that jumps straight to the tab.

An agent running on a remote host cannot reach the local socket, but MacMoba also watches for the terminal bell and for output resuming after a long silence, so it still marks the tab. **⌥⌘U** cycles to the next tab waiting for you.

---

## Macros and MultiExec

### Macros

Add them in **Library (⌥⌘L) → Macros**. A macro is a piece of text plus a **"press Return after sending"** switch — with it off, the text waits at the prompt for you to confirm, which is what a dangerous command deserves.

The first nine get **⌃⌘1–9** automatically; the rest stay available in the **Macros menu**.

A macro goes through **exactly the same send path as your own typing**, so it obeys MultiExec broadcast. That is deliberate, and it is also why it is dangerous: a macro plus broadcast runs on the whole fleet from one keystroke. MacMoba asks first by default — turn that off under **Settings → General**, "Ask before a macro runs on every connected session".

### MultiExec (broadcast input)

The **MultiExec** button in the toolbar, or **⇧⌘B**. While it is on, what you type in one pane goes to **every connected terminal in every window**.

**Turning it on gathers the terminal tabs into a grid**, and turning it off hands them back to their own tabs. The reason is simple: **broadcasting to sessions you cannot see** is the thing this feature most needs to avoid.

**Leaving the group**: while broadcasting, each pane shows an antenna button in its top-right corner; clicking it takes that pane out. **The pane you are typing in always receives its own keystrokes** — a terminal that ignores your typing is not a feature, it is a fault.

When something has been taken out, the toolbar icon changes to the **struck-through** antenna, so you can see this broadcast is not going everywhere.

Remote desktops and web tabs take no part in broadcasting — there is no stream of bytes to type into.


## Keyboard and mouse on a remote desktop

**Clicking into a VNC screen captures input**, the way VMware and Parallels do:

- The whole keyboard goes to the remote machine — including **⌃Space**, so you can switch the **remote** input method (the 🌐 key cannot do this: macOS handles it below the app, which never sees it)
- The pointer is decoupled from the local cursor and driven by raw movement, so it **does not stop at the window edge**
- **Press ⌃⌥ and let go** to release. Holding modifiers and pressing nothing means nothing to any program, so the gesture cannot collide with the remote
- Escape is always passed straight through and takes no part in releasing — vim, or Claude Code running over there, will not be tripped by it

The first capture asks for **Accessibility** permission: that is the only way to suppress this Mac's own shortcuts (⌘Tab, Spotlight). **Declining still works** — those keys simply stay local. Granting it needs a restart of MacMoba.

Turn the whole behaviour off in **Session → Capture Input on Click**.

One more thing about input methods: MacMoba always sends the **physical key** (translated through the ASCII-capable layout), whatever input source is selected locally — composition belongs to the machine you are typing into.

### Clipboard

ASCII crosses automatically in both directions with the usual ⌘C / ⌘V. **Chinese and anything else outside Latin-1 does not** — RFB's clipboard message cannot carry it. Each direction has its own way round:

| What you want | Keys | How it gets there |
|---|---|---|
| Paste local text into the remote | **⌥⌘V** | Typed in character by character, using X11 Unicode keysyms |
| Copy from the remote back | **⌥⌘C** | Runs `pbpaste` over **that machine's own SSH session** (`xclip`/`xsel` on Linux) |

⌥⌘C needs a saved SSH session pointing at the **same host**; if there is none it tells you which hosts your SSH sessions do point at, so you can line them up. Neither chord is forwarded to the remote, so both keep working while input is captured.

---

## Transferring files

**SFTP panel** (the folder button in the toolbar): two-pane browsing, drag in to upload, drag out to Finder to download, Quick Look, chmod.

**Drag onto the terminal**: an SSH pane offers two landing zones — **Upload via SFTP** on the left (into the panel's current directory), **Send via ZMODEM** on the right.

**ZMODEM** (the remote needs `lrzsz`):

```bash
# Download: run this on the remote; MacMoba takes over and saves to ~/Downloads
sz report.log

# Upload: Session → Send File (ZMODEM)…
# You do not need to run rz first — MacMoba starts it. If you already did, it notices and skips.
```

Files `rz` receives land in **the directory it was run from**.

---

## Updates

MacMoba uses [Sparkle](https://sparkle-project.org/): it checks once a day, asks before downloading, verifies the EdDSA signature and the Developer ID signature, then replaces itself and restarts.

To check by hand: **MacMoba → Check for Updates…**

---

## Restoring your session

The tabs you had open are remembered and reconnected on the next launch (turn it off in **Settings → General**). **The split layout comes back too** — three shells beside a remote desktop return as three shells beside a remote desktop; a session deleted in the meantime simply costs its own pane. After the Mac wakes, terminals that dropped while it slept reconnect themselves; the ones that survived are left alone, scrollback intact.

When a connection ends, the pane sits at "Connection closed": **Return reconnects**, **Escape closes it** (just that pane, in a split).

**The state of the remote processes cannot be restored** — reconnecting is a new SSH connection. To keep work alive over there, use `tmux`/`screen`, or connect with Mosh.

---

## Next

- **⌘K** quick connect: type `user@host:port` without saving a session first
- **⇧⌘0** overview: thumbnails of every connection in every window
- **⌥⌘I** inspector: single-click to see a session and its reachability, double-click to connect
- **⌥⌘L** Library: macros, shared credentials and **session templates** (see above)
- **Tools menu**: SSH key generator, network tools (Wake-on-LAN / port scan / DNS), trusted host management

---

## Known limitations

- **arm64 only**: an Intel Mac cannot run it
- **No RSA keys**: the underlying SwiftNIO SSH supports ed25519 and ECDSA only, so use `ssh-keygen -t ed25519`
- **No ssh-agent, no keyboard-interactive (2FA/OTP)**: not offered by the upstream library
- **X11 forwarding** needs XQuartz with TCP listening enabled (`defaults write org.xquartz.X11 nolisten_tcp -bool false`, then log out and back in). SwiftNIO SSH has no native x11 channel, so MacMoba uses the equivalent remote forward: the server sends connections on `localhost:600N` back to this Mac, and `DISPLAY` is set for you
- **Session logs are plaintext**: whatever appears on screen is written to them (file 0600)
- **The VNC clipboard is Latin-1 only**: a protocol limit, so Chinese cannot cross — use ⌥⌘V / ⌥⌘C (see "Clipboard")
- **A tunnel can only be carried by an SSH or Mosh session**: it is an SSH channel, which a remote desktop or serial line cannot host, so those are not offered in the picker (see "SSH tunnels")

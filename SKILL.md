---
name: agent-tether
description: Use when the user wants you (the agent) to reach, run commands on, copy files to, or keep permanent remote access to their own Windows, macOS or Linux machine, including before anyone signs in, without port forwarding or a VPN account. Sets up a tailcat SSH listener as a boot-time service, locked to your client key and SSH key, and covers status, troubleshooting and removal.
version: 0.1.0
author: Sakina
license: MIT
---

# agent-tether

This skill gives you a permanent, private remote shell on a machine the user owns. It runs
[tailcat](https://github.com/tailscale/tailcat) (Tailscale's serverless netcat/SSH over
WireGuard and DERP relays; no Tailscale account) on the target as a boot-time service with a
fixed address. You connect with your own keys through `scripts/tether`.

Two locks protect the target, and both are always on:

1. **Tunnel lock**: `tailcat serve --allow=nodekey:<yours>` drops every WireGuard handshake
   that does not come from your tailcat client key. Others cannot even tell a server exists.
2. **SSH lock**: `--ssh-authorized-keys=<file> ssh` (tailcat's built-in SSH server) accepts only
   your SSH public key. No passwords.

Both connections are outbound from the target, so no inbound firewall rule or port forward is
needed.

Files in this skill (paths relative to the skill directory):

| File | Runs on | Purpose |
|---|---|---|
| `scripts/tether` | your side (bash) | keys, bootstrap line, ssh/scp/push/run, checks, proxy |
| `scripts/install-linux.sh` | target | systemd user service + linger, status, uninstall |
| `scripts/install-macos.sh` | target | LaunchDaemon, status, uninstall |
| `scripts/install-windows.ps1` | target | scheduled task (S4U at startup), status, uninstall |

Keep one directory per target on your side (below: `$T`). It holds the target's address and
your keys for it. Treat it like a password store: whoever has it has a shell on the target.
`$T` can be a path, or just a name: names are looked up in `$TETHER_DIR` (default
`~/.local/share/agent-tether`), so `scripts/tether ssh my-laptop 'uname -a'` works once the
directory `$TETHER_DIR/my-laptop` exists. `scripts/tether list` shows the saved targets.

Do not trust the flag names in this file blindly. tailcat makes no CLI stability promises.
Before giving commands, check them against `tailcat --help`, `tailcat serve --help` and
`tailcat genkey --help` of the version that is installed (this skill was written against
v0.7.0). If they differ, follow the binary and tell the user.

## Step 1: ask first

Before any command, ask the user these questions in one go (use your question tool if you
have one). Explain the privilege question plainly.

1. **Which OS is the target?** Windows, macOS, or Linux. For Linux: which distro, and does it
   use systemd (`ps -p 1 -o comm=` prints `systemd`)? This installer needs systemd.
2. **Are you an administrator on it?** (Windows: can you open "Terminal (Admin)"? macOS/Linux:
   can you use `sudo`?) Without admin rights the service can only run after the user signs in.
3. **After setup, may I act as administrator without asking you each time?** Say it plainly:
   "If yes, anyone who gets my keys for this machine gets full admin control of it. If no, I
   work as your normal user and ask you to run the occasional admin command yourself."
   Default: no.
4. **Keep the machine awake on AC power?** A sleeping machine is unreachable, and the first connection after a pause often fails while it wakes. Default: no.
5. **Do you also want me to control the desktop (clicks, typing, screenshots)?** If yes, see
   "GUI control" below. The remote shell works without it.
6. A short name for this machine (used for `$T` and nothing else).

## Step 2: look things up for that target

- Current tailcat install method for that OS, from
  https://github.com/tailscale/tailcat/blob/main/INSTALL.md . As of v0.7.0:
  - macOS: `brew install tailcat` (Homebrew); Nix and conda-forge also exist.
  - Windows: `scoop install tailcat` (Scoop main bucket), or the release zip from
    https://github.com/tailscale/tailcat/releases . INSTALL.md does not list winget; if the
    user prefers winget, check `winget search tailcat` before suggesting it.
  - Linux: `.deb`/`.rpm`/static tarball from the releases page, AUR `tailcat` or `tailcat-bin`,
    Nix, conda-forge. Avoid the Snap for this: it is strictly confined and keeps its config
    under `~/snap`.
- Install tailcat on your own side too, and check `tailcat version`. Your side and the
  target should run the same or close versions.

## Step 3: make your keys

```bash
T=~/.local/share/agent-tether/<target-name>
scripts/tether keygen "$T" --keys 4   # prints NODEKEY=nodekey:... (one per key) and SSH_PUBKEY=...
scripts/tether bootstrap "$T" linux   # or macos / windows; prints the one-time command
```

`keygen` is idempotent. `bootstrap` records the OS in `$T/os` and prints a single line with
your nodekeys and SSH public key already embedded, so the user never types a key.

Why several client keys: the DERP relay routes by node key, so two connections open at the
same time with the same client key take the route from each other, and new dials time out
while the target is fine. `tether` gives each live connection its own key from the pool
(`client.private.json`, `client-2.private.json`, ...) and holds a lock on it while the
connection lasts (needs `flock`, which Linux has; elsewhere it uses the first key). One key
is enough if you never run two connections at once. Every key in the pool goes into the
target's `--allow` list.

## Step 4: the one-time elevated bootstrap (the only step the user does)

Give the user exactly one line to paste, plus how to open the right terminal. It starts a
temporary listener with a throwaway address (`--key=new`), locked with the same two locks.
It runs elevated once, so the user never has to approve anything again.

**Linux / macOS**: install tailcat if missing (Step 2), open a terminal, paste the line from
`tether bootstrap`. It looks like:

```bash
bash -c 'sudo "$(command -v tailcat)" serve --key=new --allow=nodekey:<yours> --ssh-authorized-keys="ssh-ed25519 AAAA... agent-tether" ssh'
```

The `bash -c` wrapper makes it work from fish or zsh too; `command -v` finds tailcat even if
`sudo`'s PATH does not include it. The user types her password once for sudo. Your shell on
this listener is **root** (tailcat runs the session as the user running the listener). If
the user is not allowed to use sudo, use `tether bootstrap "$T" linux --no-sudo`; the
installer then runs as her and enabling lingering may need an admin later.

**Windows**: install tailcat in a normal PowerShell window first (Scoop refuses or warns when
run as admin). Then open **Terminal (Admin)** (right-click Start, or Win+X) and paste the line:

```powershell
tailcat serve --key=new --allow=nodekey:<yours> --ssh-authorized-keys="ssh-ed25519 AAAA... agent-tether" ssh
```

tailcat starts session shells with plain `CreateProcess`, so they inherit the listener's
token: an elevated listener gives you elevated PowerShell sessions. If the user is not an
admin, have her paste it into a normal window instead; the installer then falls back to an
at-logon task.

In both cases tailcat prints a line like
`# 🐈 Server listening with new address: tc...`. Ask the user to copy the `tc...` part and
paste it to you (copy/paste, never retype). Then:

```bash
scripts/tether set-address "$T" 'tc...'
scripts/tether check "$T"     # expect 4 x PASS
```

Ask her to leave that window open until Step 5 is done.

## Step 5: convert it into the permanent service

You do this over the temporary session. The installer creates a saved server key with a fixed
DERP region (so the address never changes), the boot-time service, and prints `ADDRESS=tc...`.

**Linux** (session is root; pass the real user):

```bash
scripts/tether ssh "$T" 'loginctl list-users'   # find the user if you are not sure
scripts/tether run "$T" scripts/install-linux.sh install --user <user> \
  --client-nodekey "nodekey:..." --authorized-key "ssh-ed25519 AAAA... agent-tether" \
  [--privileged] [--stay-awake]
```

Result: `~<user>/.config/systemd/user/agent-tether.service` plus `loginctl enable-linger`, so
it starts at boot without a login. Why a user unit and not a system unit with `User=`: it is the
pattern proven on real machines, everything belongs to the user, and the user (or you,
unprivileged) can remove it without root. `--privileged` installs
`/etc/sudoers.d/agent-tether` (`<user> ALL=(ALL:ALL) NOPASSWD: ALL`, checked with
`visudo -cf` first) instead of running the listener as root: your shell stays a normal user,
admin actions are explicit `sudo -n ...` calls that land in the system log, and the grant is
one file to delete. `--stay-awake` masks the systemd sleep targets (desktop power settings
then cannot suspend either).

**macOS** (session is root):

```bash
scripts/tether run "$T" scripts/install-macos.sh install --user <user> \
  --client-nodekey "nodekey:..." --authorized-key "ssh-ed25519 AAAA... agent-tether" \
  [--privileged] [--stay-awake]
```

On a Mac the bootstrap can be skipped: the user can download `install-macos.sh` and run it
herself in Terminal, as herself (not with sudo), with the same options. It asks for her
password once, for the LaunchDaemon. If she cancels the password prompt, or anything else
stops it, running the same line again is safe: the saved key, and so the address, are kept.
Afterwards she sends you the `ADDRESS=` line; with `--open-settings` it also opens System
Settings at Full Disk Access with the tailcat binary shown in Finder.

tailcat comes from Homebrew: the installer runs `brew install tailcat` (as the user) when
Homebrew is there and tailcat is not. GitHub releases have no macOS build, so without
Homebrew build it from a release tag (`git clone --branch v0.7.0
https://github.com/tailscale/tailcat && cd tailcat && GOOS=darwin GOARCH=arm64 go build -o
tailcat-darwin-arm64 ./cmd/tailcat`) and pass `--tailcat <file> --tailcat-sha256 <hex>`;
the installer checks it and copies it into the agent folder.

Result: `/Library/LaunchDaemons/agent-tether.plist` with `UserName=<user>`, `RunAtLoad`,
`KeepAlive`, `ThrottleInterval 10`, log at `~<user>/.config/agent-tether/tailcat.log`. A
LaunchDaemon starts at boot, before login, and `UserName` drops it to the user. A LaunchAgent
(`~/Library/LaunchAgents`) would only run after she logs in, which is why it is not used for
the shell. macOS Remote Login stays off: tailcat brings its own SSH server.
`--stay-awake` runs `pmset -c sleep 0` (restored on uninstall). Note for the user: macOS
privacy protection (TCC) blocks the shell from Desktop, Documents and Downloads until the
tailcat binary is given Full Disk Access in System Settings; the installer prints which file.
A Homebrew upgrade moves the binary, so the grant may need switching on again.

**Windows** (session is elevated PowerShell):

```bash
scripts/tether push "$T" scripts/install-windows.ps1 '%TEMP%\agent-tether-install.ps1'
scripts/tether ssh "$T" 'powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\agent-tether-install.ps1" install -ClientNodeKey nodekey:... -AuthorizedKey "ssh-ed25519 AAAA... agent-tether"'
# optional: -Privileged  -NoSleepOnAC
```

Result: scheduled task `agent-tether`, trigger at startup, logon type S4U (no password
stored; Microsoft: runs non-interactively, without network credentials or access to
EFS-encrypted files), RunLevel `Limited`, or `Highest` with `-Privileged` (for an admin
account that is a full elevated token without UAC prompts). Restarts every minute if it dies,
no time limit, runs on battery. If the session is not elevated, Windows refuses S4U/at-startup
("Access is denied"), so the script registers an at-logon, Interactive task instead and says
so. `-NoSleepOnAC` sets sleep and hibernate on AC to never (restored on uninstall).

**Then, on your side** (all OSes):

```bash
cp "$T/address" "$T/address.bootstrap"
scripts/tether set-address "$T" '<ADDRESS from the installer output>'
scripts/tether check "$T"   # 4 x PASS: your key works, a fresh tailcat key and a fresh SSH key are refused
```

Finally stop the temporary listener. Simplest: ask the user to press Ctrl+C in that window and
close it. Or end it yourself through the bootstrap address (this drops that session, which is
expected): on Linux/macOS run `pkill -f 'serve --key=new --allow=nodekey:<yours>'` in it;
on Windows, `Stop-Process -Id (Get-CimInstance Win32_Process -Filter "ProcessId=$PID").ParentProcessId`
(the session's PowerShell is a direct child of the listener). Point that one call at the
bootstrap address: `TETHER_ADDRESS="$(cat "$T/address.bootstrap")" scripts/tether ssh "$T" '...'`.

If the user agrees, test a reboot: reboot, wait, and run `tether check` without her signing
in. Tell her that a disk encryption password at boot (LUKS, FileVault after a restart) holds
the machine before the service can start; BitLocker with TPM-only unlock does not.

## Step 6: using it

```bash
scripts/tether ssh "$T" 'uname -a'                     # one command
scripts/tether ssh "$T"                                # interactive shell
scripts/tether run "$T" ./job.sh arg1                  # POSIX: local script via bash -s
scripts/tether run "$T" --with data.json ./job.ps1 -X 1 # Windows: copied to <remote-dir>\run, run with -File
scripts/tether scp "$T" ./file target:/tmp/file        # copy (remote side is always "target:")
scripts/tether scp "$T" target:/var/log/syslog ./
scripts/tether push "$T" ./file '/tmp/file'            # copy through stdin, byte for byte (Windows paths too; no BOM, no re-encoding)
scripts/tether ping "$T"                               # tunnel only; says DERP or direct path
scripts/tether forward "$T" <address> 18080:8080      # tailcat forward to a service that accepts the same client keys
```

- **Copies** use scp's legacy protocol (`-O`), because tailcat's SSH server has no SFTP.
  On Windows, `target:` paths are relative to the user's home; an absolute path needs a
  leading slash (`target:/D:/dir/file`).
- **`run` on Windows** copies the script (and any `--with` files) to `<remote-dir>\run\`
  (`$T/remote-dir`, default `.config/agent-tether`) and runs it with
  `powershell -NoProfile -ExecutionPolicy Bypass -File`. Inline PowerShell sent through ssh
  breaks on quotes and `$env:`, so put anything longer than one line in a script.
- **Flaky dials** (`Dial: context deadline exceeded`, ssh exit 255, mostly the first
  connection after a pause): the target was asleep. A Mac with the default power settings
  idle-sleeps within minutes and wakes for short windows (Power Nap, 2 to 45 seconds) to
  check in; tailcat is suspended while it sleeps. A ping can be answered at the start of a
  window and the machine sleeps again before the TCP connection opens, and tailcat gives up
  a dial after 10 seconds. The relay is not involved. The fix is on the target: install
  with `--stay-awake` (macOS: `pmset -c sleep 0`) so it stays up on AC power, or tell the
  user to keep it awake; otherwise rerun the command. `tether` does not retry for you.
- **POSIX targets**: the command runs through the user's login shell with `-c`, which may be
  fish. For anything beyond a simple command use `tether run` (it sends `bash -s`) or wrap in
  `bash -c '...'`. PATH in the session is minimal (`/usr/local/bin:/usr/bin:/bin`); use full
  paths or `bash -lc` for Homebrew, `~/.local/bin`, etc.
- **Windows targets**: commands run in PowerShell (`pwsh` if installed, else Windows PowerShell
  5.1). Write PowerShell, not cmd. A session under the S4U task runs in session 0: it cannot
  show windows on the user's desktop.
- **Admin actions**: privileged Linux/macOS: `sudo -n <cmd>`. Privileged Windows: the shell is
  already elevated. Unprivileged: give the user the exact command to run in her own admin
  terminal, and say why.
- **Long jobs**: the job dies with the SSH session. Linux: `systemd-run --user <cmd>`;
  macOS: `nohup <cmd> >log 2>&1 &`; Windows: a one-shot scheduled task or `Start-Process`.

## Status

```bash
scripts/tether run "$T" scripts/install-linux.sh status       # Linux (as the user)
scripts/tether ssh "$T" 'sudo -n launchctl print system/agent-tether | head -20'   # macOS (print needs root)
scripts/tether ssh "$T" 'Get-ScheduledTask agent-tether | Select TaskName,State; Get-ScheduledTaskInfo agent-tether'  # Windows
```

## GUI control (only if the user asked for it)

Do not reimplement anything. Use your own computer-use feature and its driver; for Hermes that
is the `computer_use` toolset, which speaks MCP over stdio to **cua-driver**
([Hermes docs](https://hermes-agent.nousresearch.com/docs/user-guide/features/computer-use),
[trycua/cua](https://github.com/trycua/cua)). Other agents: their equivalent. The tether only
adds two things:

1. **The driver must run inside the signed-in desktop session**, not in the tether service:
   - Windows: the S4U task runs in session 0, which has no desktop. cua's own fix: from the
     signed-in desktop run `cua-driver autostart enable` and `cua-driver autostart kick` (an
     Interactive at-logon task in the user's session), then talk to it from the SSH side with
     `cua-driver mcp --socket \\.\pipe\cua-driver`. Someone must be signed in (or a
     disconnected session must exist). See https://cua.ai/docs/how-to-guides/driver/windows-ssh .
   - macOS: the driver runs as the user's GUI app (CuaDriver.app, a LaunchAgent-style
     process), and Accessibility plus Screen Recording must be granted by hand once in System
     Settings. Do initial consent at the Mac itself, not over SSH.
   - Linux: needs the user's graphical session. X11 works. On GNOME/KDE Wayland, input
     injection has been unreliable: trycua/cua#1982 (published binary lacked the
     `portal-libei` backend; still open) and umbrella #2004; later work added a portal
     variant and libei input (PRs #2111, #2112), but trycua/cua#3972 (Sep 2026) reports KDE
     Plasma Wayland input still refused. Run `cua-driver doctor` on the target and believe
     it over this paragraph.
2. **Reaching it over the tether**: register an MCP stdio server whose command is the SSH
   transport, e.g. `scripts/tether ssh "$T" cua-driver mcp` (Windows:
   `scripts/tether ssh "$T" cua-driver.exe mcp --socket \\.\pipe\cua-driver`). cua documents
   this pattern for plain SSH (https://cua.ai/docs/cua-driver/guides/vms-and-remote); through
   the tether it is **unverified**, so test it and tell the user. Use the full path to
   `cua-driver` if it is not on the session's minimal PATH.

## Uninstall

Before removing it remotely, tell the user: "I am connected through the service I am about
to remove, so my connection will drop in the middle. That is expected. Afterwards you can check
it is gone with: <the status command for her OS>."

Each installer's `uninstall` is idempotent and removes: the service/task/daemon, the sudoers
drop-in (if any), the stay-awake change (if it made one), lingering (if it enabled it), the
saved tailcat key, and the `agent-tether` folder. It does the service stop **last**, so
everything else is already gone when the session dies, and writes a log to
`~/agent-tether-uninstall.log` (`%USERPROFILE%\agent-tether-uninstall.log` on Windows).
tailcat itself stays installed; ask the user whether to remove it too
(`brew uninstall tailcat`, `scoop uninstall tailcat`, or her package manager).

- **Linux**: copy the script over, then run it detached (a transient systemd unit, so it
  survives the service's cgroup being stopped; a plain `nohup` child would be killed with it):
  ```bash
  scripts/tether push "$T" scripts/install-linux.sh /tmp/agent-tether-install.sh
  scripts/tether ssh "$T" 'bash /tmp/agent-tether-install.sh uninstall --detach'
  ```
  Removing the sudoers drop-in or unmasking sleep needs root: works if privileged (it uses
  `sudo -n`), otherwise the log lists the commands for the user.
- **macOS** (needs root, so privileged mode, or the user runs it):
  ```bash
  scripts/tether push "$T" scripts/install-macos.sh /tmp/agent-tether-install.sh
  scripts/tether ssh "$T" 'sudo -n bash /tmp/agent-tether-install.sh uninstall --user <user>'
  ```
- **Windows**: a running `tailcat.exe` cannot be deleted or replaced while it runs, and it
  carries your session, so run the uninstaller from a one-shot task 15 seconds later; it
  removes the task and folder, then stops the listener process:
  ```bash
  scripts/tether push "$T" scripts/install-windows.ps1 '%TEMP%\agent-tether-install.ps1'
  scripts/tether ssh "$T" 'powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\agent-tether-install.ps1" uninstall -Detach'
  ```

Manual removal for the user, at the machine (give her the block for her OS):

```bash
# Linux
systemctl --user disable --now agent-tether
rm -f ~/.config/systemd/user/agent-tether.service
rm -rf ~/.config/agent-tether
sudo rm -f /etc/sudoers.d/agent-tether
sudo loginctl disable-linger "$USER"     # only if nothing else needs lingering
sudo systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target   # only if stay-awake was used

# macOS
sudo launchctl bootout system/agent-tether
sudo rm -f /Library/LaunchDaemons/agent-tether.plist /etc/sudoers.d/agent-tether
rm -rf ~/.config/agent-tether
```

```powershell
# Windows, in Terminal (Admin)
Unregister-ScheduledTask -TaskName agent-tether -Confirm:$false
Get-Process tailcat -ErrorAction SilentlyContinue | Stop-Process -Force   # stops every tailcat
Remove-Item -Recurse -Force "$env:USERPROFILE\.config\agent-tether"
```

Then clean up your side: `scripts/tether forget "$T"` (deletes the keys and address).

## Troubleshooting

- **`tether check`: ping with your key fails.** Target off, asleep, offline, or the service is
  not running. Ask the user to look at the status command for her OS. Public DERP relays are
  rate-limited and best effort; retry after a minute.
- **New dials time out while another connection to the same target is open.** Both use the
  same client key. Make a pool (`tether keygen "$T" --keys 4`), add the new nodekeys to the
  target's `--allow` list (rerun the installer with every `--client-nodekey`).
- **Ping works, SSH login fails.** Wrong or missing `authorized_keys` in the agent-tether
  folder, or the key line has options (`command=`, `from=`): tailcat rejects those.
- **Freshly generated key is accepted.** `--allow` is missing: fix it now; the address alone is
  then a credential.
- **Linux: `Failed to connect to bus` from `systemctl --user` over SSH.** Set
  `XDG_RUNTIME_DIR=/run/user/$(id -u)` and
  `DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus` (the installer does this).
- **Linux: works only while logged in.** Lingering is off: `sudo loginctl enable-linger <user>`.
- **Linux: odd errors from simple commands.** The login shell is fish or zsh: use
  `tether run` / `bash -c`.
- **Windows: "Access is denied" registering the task.** Not elevated; the script falls back
  to at-logon. Rerun from an elevated session for at-startup.
- **Windows: task runs, but the key is not found.** Under S4U the profile environment can
  differ; the installer passes absolute paths for this reason. Keep them absolute.
- **Windows: unreachable after power-on but fine after restart.** Fast Startup resumes
  instead of booting; try a restart, or turn Fast Startup off.
- **Host key warning after reinstall.** A new address gets a new known-hosts alias
  automatically; a reused address with a new host key (tailcat's host key lives in the
  listener user's config folder) means something changed: ask before deleting
  `$T/known_hosts`.

## Security notes (tell the user the short version)

- What the locks protect: without your tailcat client key the target ignores the connection;
  without your SSH key the SSH server refuses it. The address is also a secret (it contains a
  WireGuard pre-shared key), but the setup does not rely on it staying secret.
- Your `$T` directory holds all three (address, client key, SSH key): protect it. To revoke
  access, uninstall, or reinstall with new keys.
- With "privileged" on, your keys are admin keys for that machine.
- tailcat is a Tailscale project but its README says: "Tailcat is free to use, but it comes
  with no API or CLI stability promises: the Go API, the CLI flags and output, and the wire
  format may all change. The public rate-limited Tailcat DERP relays have no uptime SLAs or
  throughput targets, and we may revoke access to them at any time, for any reason." Traffic
  stays end-to-end encrypted when relayed. For independence from the public relays, tailcat
  supports running your own DERP server (`tailcat genkey --region=<your-derp-host>`).

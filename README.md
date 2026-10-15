# agent-tether

Let your AI agent reach your own Windows, macOS or Linux machine whenever it is switched on,
through a private, key-locked SSH tunnel, with no port forwarding, VPN account or open
firewall port.

agent-tether is an agent skill ([`SKILL.md`](SKILL.md)) plus a few small scripts. The agent
(Hermes Agent, Claude Code, or any agent that can run shell commands and read skills) walks you
through setup: you paste one command on your machine, once, and the agent does the rest.

It is built on [tailcat](https://github.com/tailscale/tailcat), Tailscale's serverless
netcat/SSH over WireGuard. tailcat needs no Tailscale account and no root to run.

## How it works

```
 your machine (target)                                     agent's machine
 ┌──────────────────────────────────────┐                 ┌─────────────────────────────┐
 │ boot-time service:                   │   WireGuard     │ scripts/tether ssh <dir> ...│
 │ tailcat serve --key=<saved, fixed>   │◄──────────────► │   ssh + ProxyCommand:       │
 │   --allow=nodekey:<agent's key>      │  via DERP relay │   tailcat --key=<client>    │
 │   --ssh-authorized-keys=<agent pub>  │  or direct UDP  │           <address> 22      │
 │   ssh                                │                 │                             │
 └──────────────────────────────────────┘                 └─────────────────────────────┘
        outbound connections only                          <dir>: address + keys
```

- The target keeps a **fixed address** (a saved tailcat key with its relay region baked in).
- **Lock 1, the tunnel**: only the agent's tailcat client key may connect (`--allow`). Anyone
  else's handshake is silently ignored.
- **Lock 2, SSH**: tailcat's built-in SSH server accepts only the agent's SSH public key.
- Both sides only make outbound connections, so nothing needs to be opened on your router or
  firewall.

## Status

| OS | Service | Status |
|---|---|---|
| Linux (systemd) | systemd user unit + lingering | pattern tested on a real machine |
| Windows 10/11 | scheduled task, at startup, S4U | pattern tested on a real machine |
| macOS | LaunchDaemon with `UserName` | **untested**, needs a real Mac |

The elevated one-paste bootstrap, the privileged option (sudoers drop-in / `RunLevel Highest`)
and remote self-removal are new and not yet verified on real machines.

## Setup

Ask your agent to set up remote access with this skill. It will:

1. **Ask** which OS your machine runs, whether you are an admin there, whether it may act as
   admin later, whether to keep the machine awake, and whether you also want desktop control.
2. **Look up** the current tailcat install method for your OS:
   - macOS: `brew install tailcat`
   - Windows: `scoop install tailcat`, or the zip from the
     [releases page](https://github.com/tailscale/tailcat/releases)
   - Linux: `.deb` / `.rpm` / tarball from the releases page, or AUR `tailcat` / `tailcat-bin`
   - See tailcat's [INSTALL.md](https://github.com/tailscale/tailcat/blob/main/INSTALL.md).
3. **Give you one line to paste**, with its keys already filled in:
   - Linux / macOS: paste into a terminal; you type your password once for `sudo`.
   - Windows: paste into **Terminal (Admin)**; you confirm the UAC prompt once.
   It prints `Server listening with new address: tc...`. Copy that address back to the agent.
   This listener is temporary and uses a throwaway address.
4. **Install the permanent service** through that temporary session, check that its own keys
   work and that unknown keys are refused, and switch to the new fixed address. Then you close
   the temporary window.

From then on the machine is reachable whenever it is on, before anyone signs in. (A disk
encryption password at boot, such as LUKS, or FileVault after a restart, holds the machine
until it is entered.)

### Running the installers yourself

The installers live in `scripts/`; their options are documented at the top of each file:

```bash
# Linux, as the user (or as root with --user NAME)
scripts/install-linux.sh install --client-nodekey nodekey:<hex> --authorized-key "ssh-ed25519 AAAA... agent-tether"

# macOS
sudo scripts/install-macos.sh install --user NAME --client-nodekey nodekey:<hex> --authorized-key "ssh-ed25519 AAAA... agent-tether"
```

```powershell
# Windows, from an elevated PowerShell
powershell -ExecutionPolicy Bypass -File scripts\install-windows.ps1 install -ClientNodeKey nodekey:<hex> -AuthorizedKey "ssh-ed25519 AAAA... agent-tether"
```

Optional flags: `--privileged` / `-Privileged` (agent may act as admin without asking),
`--stay-awake` / `-NoSleepOnAC` (no sleep on AC power).

Everything on the target lives in one folder: `~/.config/agent-tether/`
(`%USERPROFILE%\.config\agent-tether\` on Windows): the server key, its address, and the
agent's authorized SSH key.

## Using it (agent side)

```bash
T=~/.local/share/agent-tether/my-laptop
scripts/tether keygen "$T"                  # agent's client key + SSH key
scripts/tether set-address "$T" 'tc...'     # the target's address
scripts/tether check "$T"                   # positive and negative connection tests
scripts/tether ssh "$T" 'uname -a'
scripts/tether run "$T" ./script.sh         # POSIX targets: runs via bash -s
scripts/tether scp "$T" ./file target:/tmp/
scripts/tether ping "$T"
```

Linux and macOS sessions use your login shell; Windows sessions use PowerShell.

## Security model

- Two independent locks (tunnel key and SSH key), both required. The address is also secret,
  but security does not depend on it.
- The agent's folder for your machine holds everything needed to log in. If you enable the
  privileged option, it is effectively an admin key to your machine. Say no unless you need it.
- Linux privileged mode is a sudoers drop-in (`/etc/sudoers.d/agent-tether`), not a root
  listener: the shell stays your user, and admin actions are explicit `sudo` calls that show up
  in the system log.
- tailcat is an open-source Tailscale project. Its README states that it "comes with no API or
  CLI stability promises" and that the public DERP relays "have no uptime SLAs or throughput
  targets, and we may revoke access to them at any time, for any reason." Relayed traffic is
  still end-to-end encrypted. You can [run your own DERP relay](https://github.com/tailscale/tailcat#bring-your-own-derp-relay).

## Troubleshooting

- **Unreachable**: machine asleep, off, offline, or the service stopped. Check status:
  - Linux: `systemctl --user status agent-tether` and `loginctl show-user "$USER" -p Linger`
  - macOS: `sudo launchctl print system/agent-tether`
  - Windows: `Get-ScheduledTask agent-tether`
- **Linux: only works while logged in**: `sudo loginctl enable-linger "$USER"`.
- **Linux over SSH: `systemctl --user` cannot connect to the bus**: set
  `XDG_RUNTIME_DIR=/run/user/$(id -u)` and
  `DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus`.
- **Windows: "Access is denied" when installing**: run from an elevated prompt. Without it the
  installer uses an at-logon task, which is reachable only after you sign in.
- **macOS: shell cannot read Desktop/Documents**: give the tailcat binary Full Disk Access in
  System Settings > Privacy & Security.

## Uninstall

The agent can remove everything itself (its connection drops halfway, which is expected), or
you can run the installer's `uninstall`:

```bash
scripts/install-linux.sh uninstall
sudo scripts/install-macos.sh uninstall --user NAME
```

```powershell
powershell -ExecutionPolicy Bypass -File scripts\install-windows.ps1 uninstall
```

It removes the service, the privilege grant, the stay-awake change, the saved key and the
`agent-tether` folder, and writes `~/agent-tether-uninstall.log`. tailcat itself stays
installed (`brew uninstall tailcat`, `scoop uninstall tailcat`, or your package manager).

Manual removal without the scripts:

```bash
# Linux
systemctl --user disable --now agent-tether
rm -f ~/.config/systemd/user/agent-tether.service
rm -rf ~/.config/agent-tether
sudo rm -f /etc/sudoers.d/agent-tether

# macOS
sudo launchctl bootout system/agent-tether
sudo rm -f /Library/LaunchDaemons/agent-tether.plist /etc/sudoers.d/agent-tether
rm -rf ~/.config/agent-tether
```

```powershell
# Windows, Terminal (Admin)
Unregister-ScheduledTask -TaskName agent-tether -Confirm:$false
Get-Process tailcat -ErrorAction SilentlyContinue | Stop-Process -Force
Remove-Item -Recurse -Force "$env:USERPROFILE\.config\agent-tether"
```

On the agent's side: `scripts/tether forget <dir>`.

## Tests

```bash
PATH=/path/to/tailcat-dir:$PATH tests/test-keygen.sh
PATH=/path/to/tailcat-dir:$PATH tests/test-linux-installer.sh   # stubs systemd, touches nothing real
shellcheck scripts/tether scripts/*.sh tests/*.sh
```

## Credits

- [tailcat](https://github.com/tailscale/tailcat) by Tailscale (BSD-3-Clause), which does all
  the networking.
- Desktop control, if you want it, comes from your agent's own computer-use driver, e.g.
  [cua-driver](https://github.com/trycua/cua); see [`SKILL.md`](SKILL.md).

## License

MIT, see [LICENSE](LICENSE).

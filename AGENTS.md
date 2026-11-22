# agent-tether

An agent skill (`SKILL.md`) plus the scripts it uses to set up and use a key-locked tailcat SSH tunnel to a Windows, macOS or Linux machine. `scripts/tether` is the client the agent runs; `scripts/install-*` are the per-OS installers the person pastes once.

## Rules

- Checks: `tests/test-*.sh`, all of them before a PR. They stub systemd, ssh and the real system and work in a temporary home, but the installer tests call the real `tailcat` for key generation, so it must be on the PATH.
- The installers run with elevated rights on someone else's machine. Keep them small and readable, and never widen what the tunnel accepts: one agent key at the tunnel, one SSH key at the server.
- README and `SKILL.md` must match what the scripts really do. When a script changes, change both in the same PR.
- Keep addresses, keys and machine names out of the repo, tests included. Examples use placeholders.
- Everything in the repo (code, docs, commits) is English.
- Conventional Commits, squash merges; PR titles are Conventional Commit subjects.

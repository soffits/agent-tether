#!/usr/bin/env bash
# Exercises scripts/install-linux.sh install/status/uninstall without touching
# the real system: systemd tools are stubbed, paths point into a temp dir.
# Uses the real tailcat binary for key generation (needs network for
# --fixed-region). This checks the script's logic, not systemd itself.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
command -v tailcat >/dev/null || { echo "SKIP: tailcat not on PATH"; exit 0; }
command -v python3 >/dev/null || { echo "SKIP: python3 needed to create a fake bus socket"; exit 0; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home" "$tmp/runtime" "$tmp/run-systemd"
calls=$tmp/calls.log

for tool in systemctl loginctl systemd-run; do
	cat >"$tmp/bin/$tool" <<EOF
#!/bin/sh
echo "$tool \$*" >> "$calls"
case "\$*" in
*is-active*) echo active ;;
*is-enabled*) echo enabled ;;
*show-user*) echo no ;;
esac
exit 0
EOF
	chmod +x "$tmp/bin/$tool"
done
printf '#!/bin/sh\nexit 1\n' >"$tmp/bin/sudo"
chmod +x "$tmp/bin/sudo"
python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$tmp/runtime/bus"

script=$tmp/install-linux.sh
sed -e "s|/run/systemd/system|$tmp/run-systemd|" \
	-e "s|^THOME=.*|THOME=$tmp/home|" \
	-e "s|^RUNTIME=.*|RUNTIME=$tmp/runtime|" \
	"$here/scripts/install-linux.sh" >"$script"

fail() { echo "FAIL: $*"; exit 1; }
export PATH="$tmp/bin:$PATH"
nk="nodekey:$(printf '%064d' 0)"

if bash "$script" install --authorized-key "ssh-ed25519 AAAA x" >/dev/null 2>&1; then fail "install without --client-nodekey succeeded"; fi

out=$(bash "$script" install --client-nodekey "$nk" --authorized-key "ssh-ed25519 AAAAC3Nza test" 2>&1) || { echo "$out"; fail "install failed"; }
dir=$tmp/home/.config/agent-tether
unit=$tmp/home/.config/systemd/user/agent-tether.service
[ -s "$dir/server.private.json" ] || fail "server key missing"
grep -q '^tc' "$dir/address" || fail "address missing"
grep -qx 'ssh-ed25519 AAAAC3Nza test' "$dir/authorized_keys" || fail "authorized_keys wrong"
grep -q -- "--allow=$nk" "$unit" || fail "unit lacks --allow"
grep -q -- "--ssh-authorized-keys=$dir/authorized_keys" "$unit" || fail "unit lacks authorized keys"
grep -q '^Restart=always' "$unit" || fail "unit lacks Restart=always"
grep -q 'enable-linger' "$calls" || fail "linger not enabled"
grep -q 'systemctl --user enable agent-tether.service' "$calls" || fail "unit not enabled"
grep -q '^ACTIVE=active' <<<"$out" || fail "status after install"
addr1=$(cat "$dir/address")

# Idempotent: second install keeps the key and address.
bash "$script" install --client-nodekey "$nk" --authorized-key "ssh-ed25519 AAAAC3Nza test" >/dev/null
[ "$(cat "$dir/address")" = "$addr1" ] || fail "reinstall changed the address"

: >"$calls"
bash "$script" uninstall >/dev/null
[ ! -e "$dir" ] || fail "dir not removed"
[ ! -e "$unit" ] || fail "unit not removed"
grep -q 'disable-linger' "$calls" || fail "linger not reverted"
tail -n1 "$calls" | grep -q 'systemctl --user stop agent-tether.service' || fail "stop is not the last step"
grep -q 'uninstall finished' "$tmp/home/agent-tether-uninstall.log" || fail "no uninstall log"
bash "$script" uninstall >/dev/null || fail "second uninstall not idempotent"

echo "PASS test-linux-installer"

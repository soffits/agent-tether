#!/usr/bin/env bash
# Exercises scripts/install-macos.sh install/status/uninstall on Linux with
# stubbed macOS tools (launchctl, dscl, plutil, brew, sudo...), paths pointing
# into a temp dir. Uses the real tailcat binary for key generation (needs
# network for --fixed-region). This checks the script's logic, not launchd.
# shellcheck disable=SC2016 # stub bodies are expanded when the stubs run
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
real_tailcat=$(command -v tailcat) || { echo "SKIP: tailcat not on PATH"; exit 0; }
command -v python3 >/dev/null || { echo "SKIP: python3 needed to check the plist"; exit 0; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home" "$tmp/LaunchDaemons" "$tmp/sudoers.d" "$tmp/brew/bin"
calls=$tmp/calls.log

stub() {
	printf '#!/bin/bash\necho "%s $*" >> "%s"\n%s\n' "$1" "$calls" "$2" >"$tmp/bin/$1"
	chmod +x "$tmp/bin/$1"
}
stub uname 'echo Darwin'
stub dscl "echo 'NFSHomeDirectory: $tmp/home'"
stub launchctl 'case "$1" in print) [ -e "'"$tmp"'/loaded" ] && printf "\tstate = running\n" ;; bootstrap) touch "'"$tmp"'/loaded" ;; bootout) rm -f "'"$tmp"'/loaded" ;; esac; exit 0'
stub plutil 'python3 -c "import plistlib,sys; plistlib.load(open(sys.argv[1],\"rb\"))" "${@: -1}"'
stub install 'eval "dst=\${$#}"; eval "src=\${$(($# - 1))}"; cp "$src" "$dst"'
stub xattr 'exit 0'
stub open 'exit 0'
stub pmset 'exit 0'
stub visudo 'exit 0'
# sudo: drop its options and run the command as is.
stub sudo 'while [ $# -gt 0 ]; do case "$1" in -n|-H) shift ;; -u) shift 2 ;; --) shift; break ;; *) break ;; esac; done; "$@"'
stub brew 'case "$1" in
list) [ -e "'"$tmp"'/brew/bin/tailcat" ] ;;
install) ln -sf "'"$real_tailcat"'" "'"$tmp"'/brew/bin/tailcat" ;;
--prefix) echo "'"$tmp"'/brew" ;;
esac'

script=$tmp/install-macos.sh
sed -e "s|^LAUNCHD_DIR=.*|LAUNCHD_DIR=$tmp/LaunchDaemons|" \
	-e "s|/etc/sudoers.d|$tmp/sudoers.d|g" \
	"$here/scripts/install-macos.sh" >"$script"

fail() { echo "FAIL: $*"; exit 1; }
export PATH="$tmp/bin:$PATH"
nk="nodekey:$(printf '%064d' 0)"
nk2="nodekey:$(printf '%064d' 1)"

if bash "$script" install --authorized-key "ssh-ed25519 AAAA x" >/dev/null 2>&1; then fail "install without --client-nodekey succeeded"; fi

out=$(bash "$script" install --client-nodekey "$nk" --client-nodekey "$nk2" --authorized-key "ssh-ed25519 AAAAC3Nza test" 2>&1) || { echo "$out"; fail "install failed"; }
dir=$tmp/home/.config/agent-tether
plist=$tmp/LaunchDaemons/agent-tether.plist
grep -q 'brew install tailcat' "$calls" || fail "tailcat not installed with Homebrew"
[ -s "$dir/server.private.json" ] || fail "server key missing"
grep -q '^tc' "$dir/address" || fail "address missing"
grep -qx 'ssh-ed25519 AAAAC3Nza test' "$dir/authorized_keys" || fail "authorized_keys wrong"
grep -q "<string>--allow=$nk,$nk2</string>" "$plist" || fail "plist lacks --allow with both keys"
grep -q "<string>$tmp/brew/bin/tailcat</string>" "$plist" || fail "plist does not run Homebrew's tailcat"
grep -q '<key>UserName</key>' "$plist" || fail "plist lacks UserName"
grep -q 'launchctl bootstrap system' "$calls" || fail "service not bootstrapped"
grep -q '^ACTIVE=running' <<<"$out" || fail "status after install: $(grep ACTIVE <<<"$out")"
grep -q 'Full Disk Access' <<<"$out" || fail "no Full Disk Access hint"
addr1=$(cat "$dir/address")

# Rerun (e.g. after an aborted sudo prompt) keeps the key and the address.
: >"$calls"
out=$(bash "$script" install --client-nodekey "$nk" --authorized-key "ssh-ed25519 AAAAC3Nza test" 2>&1) || { echo "$out"; fail "rerun failed"; }
[ "$(cat "$dir/address")" = "$addr1" ] || fail "rerun changed the address"
grep -q 'keeping the existing server key' <<<"$out" || fail "rerun did not report the kept key"
if grep -q 'brew install' "$calls"; then fail "rerun reinstalled tailcat"; fi

# A binary passed with --tailcat must match its checksum and is copied in.
cp "$real_tailcat" "$tmp/tailcat-darwin"
if bash "$script" install --client-nodekey "$nk" --tailcat "$tmp/tailcat-darwin" --tailcat-sha256 0000 >/dev/null 2>&1; then fail "checksum mismatch accepted"; fi
sum=$(shasum -a 256 "$tmp/tailcat-darwin" | awk '{print $1}')
bash "$script" install --client-nodekey "$nk" --tailcat "$tmp/tailcat-darwin" --tailcat-sha256 "$sum" >/dev/null
[ -x "$dir/bin/tailcat" ] || fail "--tailcat binary not copied"
grep -q "<string>$dir/bin/tailcat</string>" "$plist" || fail "plist does not run the copied binary"

: >"$calls"
bash "$script" uninstall >/dev/null
[ ! -e "$dir" ] || fail "dir not removed"
[ ! -e "$plist" ] || fail "plist not removed"
tail -n1 "$calls" | grep -q 'launchctl bootout system/agent-tether' || fail "bootout is not the last step"
grep -q 'uninstall finished' "$tmp/home/agent-tether-uninstall.log" || fail "no uninstall log"

echo "PASS test-macos-installer"

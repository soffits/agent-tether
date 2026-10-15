#!/usr/bin/env bash
# Runs `tether keygen` and `tether bootstrap` into a temp dir with the real
# tailcat binary and checks the files and output. Needs tailcat on PATH.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
command -v tailcat >/dev/null || { echo "SKIP: tailcat not on PATH"; exit 0; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

out=$("$here/scripts/tether" keygen "$tmp/t")
for f in client.private.json id_ed25519 id_ed25519.pub; do
	[ -s "$tmp/t/$f" ] || { echo "FAIL: $f missing"; exit 1; }
done
grep -Eq '^NODEKEY=nodekey:[0-9a-f]{64}$' <<<"$out" || { echo "FAIL: no NODEKEY line"; exit 1; }
grep -q '^SSH_PUBKEY=ssh-ed25519 ' <<<"$out" || { echo "FAIL: no SSH_PUBKEY line"; exit 1; }
[ "$(stat -c %a "$tmp/t" 2>/dev/null || stat -f %Lp "$tmp/t")" = 700 ] || { echo "FAIL: dir not 700"; exit 1; }

# keygen is idempotent: same keys the second time.
[ "$("$here/scripts/tether" keygen "$tmp/t")" = "$out" ] || { echo "FAIL: keygen not idempotent"; exit 1; }

line=$("$here/scripts/tether" bootstrap "$tmp/t" linux)
grep -q -- '--allow=nodekey:' <<<"$line" || { echo "FAIL: bootstrap lacks --allow"; exit 1; }
bash -n <<<"$line" || { echo "FAIL: bootstrap line is not valid shell"; exit 1; }
[ "$(cat "$tmp/t/os")" = linux ] || { echo "FAIL: os not recorded"; exit 1; }

"$here/scripts/tether" set-address "$tmp/t" "tcEXAMPLE" >/dev/null
[ "$(cat "$tmp/t/address")" = tcEXAMPLE ] || { echo "FAIL: address not saved"; exit 1; }
if "$here/scripts/tether" set-address "$tmp/t" "not-an-address" 2>/dev/null; then echo "FAIL: bad address accepted"; exit 1; fi

echo "PASS test-keygen"

#!/usr/bin/env bash
# Checks scripts/tether without a network: tailcat, ssh and scp are stubs that
# log how they were called. Covers target names, the client key pool, the
# commands `ssh` and `run` build (POSIX and Windows) and the failed-dial hint.
# shellcheck disable=SC2016 # stub bodies are expanded when the stubs run
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
tether=$here/scripts/tether
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
log=$tmp/calls.log
fail() { echo "FAIL: $*"; exit 1; }

cat >"$tmp/bin/tailcat" <<EOF
#!/bin/bash
echo "tailcat \$*" >> "$log"
case "\$*" in
genkey*) k=\${3#--key=}; echo key > "\$k" ;;
*printpub) printf 'nodekey:%064d\n' "\$(printf '%s' "\$1" | cksum | cut -d' ' -f1)" ;;
*" 22") sleep 2 ;;
esac
EOF
cat >"$tmp/bin/ssh" <<EOF
#!/bin/bash
printf 'ssh' >> "$log"; printf ' [%s]' "\$@" >> "$log"; echo >> "$log"
n=\$(cat "$tmp/ssh-fails" 2>/dev/null || echo 0)
if [ "\$n" -gt 0 ]; then echo \$((n - 1)) > "$tmp/ssh-fails"; exit 255; fi
cat > /dev/null
echo ok
EOF
cat >"$tmp/bin/scp" <<EOF
#!/bin/bash
[ \$# -eq 1 ] && exit 1   # the -O probe
printf 'scp' >> "$log"; printf ' [%s]' "\$@" >> "$log"; echo >> "$log"
EOF
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH" TETHER_DIR="$tmp/targets"

# Names resolve under TETHER_DIR; --keys makes a pool.
out=$("$tether" keygen m1 --keys 3)
[ "$(grep -c '^NODEKEY=nodekey:' <<<"$out")" = 3 ] || fail "keygen --keys 3 did not print three nodekeys"
for f in client.private.json client-2.private.json client-3.private.json id_ed25519; do
	[ -s "$TETHER_DIR/m1/$f" ] || fail "$f missing"
done
line=$("$tether" bootstrap m1 linux)
[ "$(grep -o 'nodekey:' <<<"$line" | wc -l)" -eq 3 ] || fail "bootstrap does not allow every pool key"
"$tether" set-address m1 tcEXAMPLE >/dev/null
[ "$("$tether" list)" = "$(printf 'm1\tlinux')" ] || fail "list: $("$tether" list)"

# ssh builds one command with the target's key, known_hosts and proxy.
: >"$log"
[ "$("$tether" ssh m1 hostname)" = ok ] || fail "ssh output"
call=$(grep '^ssh' "$log")
for want in "[-i] [$TETHER_DIR/m1/id_ed25519]" "[UserKnownHostsFile=$TETHER_DIR/m1/known_hosts]" \
	"[ProxyCommand=$tether proxy $TETHER_DIR/m1]" "[target] [hostname]"; do
	grep -qF -- "$want" <<<"$call" || fail "ssh call lacks $want: $call"
done

# Two proxies at once take different client keys.
: >"$log"
"$tether" proxy m1 & p1=$!
sleep 0.5
"$tether" proxy m1 & p2=$!
wait "$p1" "$p2"
[ "$(grep -c ' 22$' "$log")" = 2 ] || fail "proxies did not dial"
[ "$(grep ' 22$' "$log" | sort -u | wc -l)" = 2 ] || fail "two proxies shared a client key: $(cat "$log")"

# POSIX run feeds the script to bash -s.
printf 'echo hi\n' >"$tmp/s.sh"
: >"$log"
"$tether" run m1 "$tmp/s.sh" 'a b' >/dev/null
grep -qF '[bash -s -- a\ b]' "$log" || fail "posix run: $(cat "$log")"

# Windows run copies the script and extra files to <remote-dir>/run, then runs it with -File.
echo windows >"$TETHER_DIR/m1/os"
echo .config/me >"$TETHER_DIR/m1/remote-dir"
printf 'Write-Output hi\n' >"$tmp/x.ps1"
echo data >"$tmp/extra.txt"
: >"$log"
"$tether" run m1 --with "$tmp/extra.txt" "$tmp/x.ps1" -Flag 1 >/dev/null
grep -qF "[$tmp/extra.txt] [target:.config/me/run/extra.txt]" "$log" || fail "extra file not copied: $(cat "$log")"
grep -qF "[$tmp/x.ps1] [target:.config/me/run/x.ps1]" "$log" || fail "script not copied"
grep '^scp' "$log" | grep -qF '[-O]' || fail "scp without -O (tailcat has no SFTP)"
grep -qF '[powershell] [-NoProfile] [-ExecutionPolicy] [Bypass] [-File] [.config\me\run\x.ps1] [-Flag] [1]' "$log" ||
	fail "windows run command: $(grep '^ssh' "$log" | tail -1)"

# A connection that fails to open is not retried; the error says what it usually means.
echo 1 >"$tmp/ssh-fails"
if out=$("$tether" ssh m1 hostname 2>&1); then fail "failed dial succeeded"; fi
case "$out" in *"may have been asleep"*) ;; *) fail "no hint after a failed dial: $out" ;; esac
[ "$(cat "$tmp/ssh-fails")" = 0 ] || fail "failed dial was retried"
[ "$("$tether" ssh m1 hostname 2>/dev/null)" = ok ] || fail "ssh after a failed dial"

echo "PASS test-tether"

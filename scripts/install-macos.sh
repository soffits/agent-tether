#!/usr/bin/env bash
# agent-tether target installer for macOS (launchd). UNTESTED on a real Mac.
# Runs `tailcat serve ... ssh` as a LaunchDaemon with UserName set to the
# target user: it starts at boot, before anyone logs in, and the SSH shell
# runs as that user (not root).
#
#   sudo install-macos.sh install   --user NAME --client-nodekey nodekey:... --authorized-key "ssh-ed25519 AAAA..." [options]
#   sudo install-macos.sh status    --user NAME [options]
#   sudo install-macos.sh uninstall --user NAME [options]
#
# Needs root (a LaunchDaemon lives in /Library/LaunchDaemons). Options:
#   --user NAME               account the service runs as (default: the invoking user)
#   --service NAME            launchd label and file name (default: agent-tether)
#   --dir PATH                agent files (default: ~<user>/.config/agent-tether)
#   --key NAME|PATH           tailcat server key (default: <dir>/server.private.json)
#   --client-nodekey KEY      the agent's tailcat client key, for --allow (repeatable)
#   --authorized-key LINE     the agent's SSH public key line (repeatable)
#   --authorized-keys-file F  copy SSH public keys from a file instead
#   --tailcat PATH            tailcat binary (default: found on PATH or in Homebrew)
#   --privileged              let the user run sudo without a password (sudoers drop-in)
#   --stay-awake              never sleep on AC power (pmset -c sleep 0)
set -euo pipefail

ACTION=${1:-}
[ $# -gt 0 ] && shift

TUSER=""
SERVICE=agent-tether
DIR=""
KEY=""
NODEKEYS=()
PUBKEYS=()
PUBKEYS_FILE=""
TAILCAT_BIN=""
PRIVILEGED=0
STAY_AWAKE=0
ORIG_ARGS=("$@")

die() { echo "install-macos: $*" >&2; exit 1; }
log() { echo "agent-tether: $*"; }

while [ $# -gt 0 ]; do
	case "$1" in
	--user) TUSER=$2; shift 2 ;;
	--service) SERVICE=$2; shift 2 ;;
	--dir) DIR=$2; shift 2 ;;
	--key) KEY=$2; shift 2 ;;
	--client-nodekey) NODEKEYS+=("$2"); shift 2 ;;
	--authorized-key) PUBKEYS+=("$2"); shift 2 ;;
	--authorized-keys-file) PUBKEYS_FILE=$2; shift 2 ;;
	--tailcat) TAILCAT_BIN=$2; shift 2 ;;
	--privileged) PRIVILEGED=1; shift ;;
	--stay-awake) STAY_AWAKE=1; shift ;;
	*) die "unknown option: $1" ;;
	esac
done

case "$SERVICE" in *[!A-Za-z0-9_.-]* | "") die "--service may only use letters, digits, . _ -" ;; esac
[ "$(uname -s)" = Darwin ] || die "this installer is for macOS"

# Re-run through passwordless sudo when possible (the --privileged setup).
if [ "$(id -u)" -ne 0 ]; then
	[ "$ACTION" = status ] || {
		if [ -f "$0" ] && sudo -n true 2>/dev/null; then
			exec sudo -n /bin/bash "$0" "$ACTION" --user "${TUSER:-$(id -un)}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
		fi
		die "needs root: run it with sudo"
	}
fi

TUSER=${TUSER:-${SUDO_USER:-$(id -un)}}
[ -n "$TUSER" ] && [ "$TUSER" != root ] || die "pass --user <name> for the account the service should run as"
id "$TUSER" >/dev/null 2>&1 || die "no such user: $TUSER"
THOME=$(dscl . -read "/Users/$TUSER" NFSHomeDirectory | sed 's/^NFSHomeDirectory: //')
[ -d "$THOME" ] || die "cannot find the home directory of $TUSER"

DIR=${DIR:-$THOME/.config/agent-tether}
KEY=${KEY:-$DIR/server.private.json}
PLIST=/Library/LaunchDaemons/$SERVICE.plist
SUDOERS=/etc/sudoers.d/$SERVICE
LOGFILE=$THOME/$SERVICE-uninstall.log

as_user() { sudo -H -u "$TUSER" -- "$@"; }
write_as_user() {
	# shellcheck disable=SC2016 # $1 is expanded by the inner sh
	as_user sh -c 'umask 077; cat > "$1"' sh "$1"
}
key_is_path() { case "$KEY" in */*) return 0 ;; *) return 1 ;; esac; }

find_tailcat() {
	if [ -n "$TAILCAT_BIN" ]; then
		[ -x "$TAILCAT_BIN" ] || die "not executable: $TAILCAT_BIN"
		return
	fi
	local c
	for c in "$(command -v tailcat 2>/dev/null || true)" /opt/homebrew/bin/tailcat /usr/local/bin/tailcat "$THOME/go/bin/tailcat"; do
		if [ -n "$c" ] && [ -x "$c" ]; then
			TAILCAT_BIN=$c
			break
		fi
	done
	[ -n "$TAILCAT_BIN" ] || die "tailcat not found; install it first (brew install tailcat) or pass --tailcat PATH"
}

xml_escape() {
	printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

do_install() {
	find_tailcat
	[ ${#NODEKEYS[@]} -gt 0 ] || die "--client-nodekey is required (the agent's tailcat client key; without it any client could connect)"
	local k
	for k in "${NODEKEYS[@]}"; do
		case "$k" in nodekey:*) ;; *) die "client keys look like nodekey:<hex>, got: $k" ;; esac
	done
	[ ${#PUBKEYS[@]} -gt 0 ] || [ -n "$PUBKEYS_FILE" ] || [ -s "$DIR/authorized_keys" ] ||
		die "--authorized-key or --authorized-keys-file is required"

	as_user mkdir -p "$DIR"
	as_user chmod 700 "$DIR"

	if [ ${#PUBKEYS[@]} -gt 0 ] || [ -n "$PUBKEYS_FILE" ]; then
		{
			if [ ${#PUBKEYS[@]} -gt 0 ]; then printf '%s\n' "${PUBKEYS[@]}"; fi
			if [ -n "$PUBKEYS_FILE" ]; then cat "$PUBKEYS_FILE"; fi
		} | write_as_user "$DIR/authorized_keys"
	fi

	if key_is_path; then
		if [ ! -s "$KEY" ]; then
			as_user "$TAILCAT_BIN" genkey --key="$KEY" --fixed-region | write_as_user "$DIR/address"
			log "created server key $KEY"
		fi
	elif ! as_user "$TAILCAT_BIN" genkey --list 2>/dev/null | grep -qx "$KEY"; then
		as_user "$TAILCAT_BIN" genkey --key="$KEY" --fixed-region | write_as_user "$DIR/address"
		log "created server key named $KEY"
	fi

	local allow args=() a
	allow=$(IFS=,; echo "${NODEKEYS[*]}")
	for a in "$TAILCAT_BIN" serve "--key=$KEY" "--allow=$allow" "--ssh-authorized-keys=$DIR/authorized_keys" ssh; do
		args+=("		<string>$(xml_escape "$a")</string>")
	done

	cat >"$PLIST.tmp" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$SERVICE</string>
	<key>ProgramArguments</key>
	<array>
$(printf '%s\n' "${args[@]}")
	</array>
	<key>UserName</key>
	<string>$(xml_escape "$TUSER")</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>HOME</key>
		<string>$(xml_escape "$THOME")</string>
		<key>TAILCAT_ADDR_FILE</key>
		<string>$(xml_escape "$DIR/address")</string>
	</dict>
	<key>WorkingDirectory</key>
	<string>$(xml_escape "$THOME")</string>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ThrottleInterval</key>
	<integer>10</integer>
	<key>StandardOutPath</key>
	<string>$(xml_escape "$DIR/tailcat.log")</string>
	<key>StandardErrorPath</key>
	<string>$(xml_escape "$DIR/tailcat.log")</string>
</dict>
</plist>
EOF
	plutil -lint "$PLIST.tmp" >/dev/null || die "generated plist is invalid: $PLIST.tmp"
	launchctl bootout "system/$SERVICE" 2>/dev/null || true
	install -m 0644 -o root -g wheel "$PLIST.tmp" "$PLIST"
	rm -f "$PLIST.tmp"
	launchctl enable "system/$SERVICE"
	launchctl bootstrap system "$PLIST"
	log "installed and started $PLIST"

	if [ "$PRIVILEGED" -eq 1 ]; then
		local tmp
		tmp=$(mktemp)
		printf '# agent-tether: lets %s run sudo without a password. Remove this file to revoke.\n%s ALL=(ALL) NOPASSWD: ALL\n' "$TUSER" "$TUSER" >"$tmp"
		if visudo -cf "$tmp" >/dev/null; then
			mkdir -p /etc/sudoers.d
			install -m 0440 -o root -g wheel "$tmp" "$SUDOERS"
			log "installed $SUDOERS (passwordless sudo for $TUSER)"
		else
			log "warning: sudoers check failed; continuing unprivileged"
		fi
		rm -f "$tmp"
	fi

	if [ "$STAY_AWAKE" -eq 1 ]; then
		local prev
		prev=$(pmset -g custom | awk '/^AC Power:/{ac=1; next} /^[A-Za-z].*:$/{ac=0} ac && $1=="sleep"{print $2}')
		printf '%s\n' "${prev:-1}" | write_as_user "$DIR/stay-awake-by-installer"
		pmset -c sleep 0
		log "system sleep on AC power disabled (was: ${prev:-unknown})"
	fi

	sleep 3
	do_status
}

do_status() {
	local addr="" state
	[ -s "$DIR/address" ] && addr=$(tr -d '\r\n' <"$DIR/address")
	state=$(launchctl print "system/$SERVICE" 2>/dev/null | awk -F' = ' '/^\tstate = /{print $2; exit}')
	echo "SERVICE=$SERVICE"
	echo "USER=$TUSER"
	echo "ACTIVE=${state:-not loaded}"
	echo "PLIST=$([ -e "$PLIST" ] && echo "$PLIST" || echo missing)"
	echo "DIR=$DIR"
	echo "PRIVILEGED=$([ -e "$SUDOERS" ] && echo yes || echo no)"
	echo "STAY_AWAKE=$([ -e "$DIR/stay-awake-by-installer" ] && echo yes || echo no)"
	echo "ADDRESS=$addr"
}

do_uninstall() {
	exec > >(tee -a "$LOGFILE") 2>&1
	log "uninstall started $(date)"
	if [ -e "$SUDOERS" ]; then rm -f "$SUDOERS" && log "removed $SUDOERS"; fi
	if [ -s "$DIR/stay-awake-by-installer" ]; then
		pmset -c sleep "$(head -n1 "$DIR/stay-awake-by-installer")" && log "restored AC sleep setting"
	fi
	if ! key_is_path; then
		find_tailcat
		as_user "$TAILCAT_BIN" genkey --delete --key="$KEY" >/dev/null 2>&1 && log "deleted tailcat key $KEY"
	elif [ -e "$KEY" ] && [ "${KEY#"$DIR"/}" = "$KEY" ]; then
		rm -f "$KEY" && log "deleted $KEY"
	fi
	rm -rf "$DIR"
	rm -f "$PLIST"
	chown "$TUSER" "$LOGFILE" 2>/dev/null || true
	log "removed $PLIST and $DIR"
	log "stopping $SERVICE; an agent connected through it is disconnected now"
	log "uninstall finished $(date)"
	# Last step: bootout ends any session that runs through the service.
	launchctl bootout "system/$SERVICE" 2>/dev/null || true
}

case "$ACTION" in
install) do_install ;;
status) do_status ;;
uninstall) do_uninstall ;;
*) die "usage: install-macos.sh install|status|uninstall [options]" ;;
esac

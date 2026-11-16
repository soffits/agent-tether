#!/usr/bin/env bash
# agent-tether target installer for macOS (launchd).
# Runs `tailcat serve ... ssh` as a LaunchDaemon with UserName set to the
# target user: it starts at boot, before anyone logs in, and the SSH shell
# runs as that user (not root). macOS Remote Login stays off.
#
#   install-macos.sh install   --client-nodekey nodekey:... --authorized-key "ssh-ed25519 AAAA..." [options]
#   install-macos.sh status    [options]
#   install-macos.sh uninstall [options]
#
# Run it as the target user from a terminal: it asks for the password once
# (sudo) for the LaunchDaemon. As root (the bootstrap session), pass --user.
# Rerunning is safe: the server key, and so the address, are kept.
# Options:
#   --user NAME               account the service runs as (default: the invoking user)
#   --service NAME            launchd label and file name (default: agent-tether)
#   --dir PATH                agent files (default: ~<user>/.config/agent-tether)
#   --key PATH                tailcat server key (default: <dir>/server.private.json)
#   --client-nodekey KEY      the agent's tailcat client key, for --allow (repeatable)
#   --authorized-key LINE     the agent's SSH public key line (repeatable)
#   --authorized-keys-file F  copy SSH public keys from a file instead
#   --tailcat PATH            use this tailcat binary instead of Homebrew's; it is
#                             copied to <dir>/bin/tailcat
#   --tailcat-sha256 HEX      refuse --tailcat unless its SHA-256 matches
#   --privileged              let the user run sudo without a password (sudoers drop-in)
#   --stay-awake              never sleep on AC power (pmset -c sleep 0)
#   --open-settings           open Finder at the tailcat binary and System Settings at
#                             Full Disk Access (run as the user, at the Mac)
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
TAILCAT_SRC=""
TAILCAT_SHA=""
PRIVILEGED=0
STAY_AWAKE=0
OPEN_SETTINGS=0
LAUNCHD_DIR=/Library/LaunchDaemons

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
	--tailcat) TAILCAT_SRC=$2; shift 2 ;;
	--tailcat-sha256) TAILCAT_SHA=$2; shift 2 ;;
	--privileged) PRIVILEGED=1; shift ;;
	--stay-awake) STAY_AWAKE=1; shift ;;
	--open-settings) OPEN_SETTINGS=1; shift ;;
	*) die "unknown option: $1" ;;
	esac
done

case "$SERVICE" in *[!A-Za-z0-9_.-]* | "") die "--service may only use letters, digits, . _ -" ;; esac
[ "$(uname -s)" = Darwin ] || die "this installer is for macOS"

IS_ROOT=0
[ "$(id -u)" -eq 0 ] && IS_ROOT=1
if [ -z "$TUSER" ]; then
	if [ "$IS_ROOT" -eq 1 ]; then TUSER=${SUDO_USER:-}; else TUSER=$(id -un); fi
fi
[ -n "$TUSER" ] && [ "$TUSER" != root ] || die "running as root: pass --user <name> for the account the service should run as"
id "$TUSER" >/dev/null 2>&1 || die "no such user: $TUSER"
[ "$IS_ROOT" -eq 1 ] || [ "$TUSER" = "$(id -un)" ] || die "run as $TUSER, or as root with --user $TUSER"
THOME=$(dscl . -read "/Users/$TUSER" NFSHomeDirectory | sed 's/^NFSHomeDirectory: //')
[ -d "$THOME" ] || die "cannot find the home directory of $TUSER"

DIR=${DIR:-$THOME/.config/agent-tether}
KEY=${KEY:-$DIR/server.private.json}
case "$KEY" in /*) ;; *) die "--key must be an absolute path" ;; esac
PLIST=$LAUNCHD_DIR/$SERVICE.plist
SUDOERS=/etc/sudoers.d/$SERVICE
LOGFILE=$THOME/$SERVICE-uninstall.log
TAILCAT_BIN=""

as_user() {
	if [ "$IS_ROOT" -eq 1 ]; then sudo -H -u "$TUSER" -- "$@"; else "$@"; fi
}
# The first call asks for the password; sudo remembers it for the next ones.
as_root() {
	if [ "$IS_ROOT" -eq 1 ]; then "$@"; else sudo "$@"; fi
}
write_as_user() {
	# shellcheck disable=SC2016 # $1 is expanded by the inner sh
	as_user sh -c 'umask 077; cat > "$1"' sh "$1"
}

brew_bin() {
	local b
	for b in "$(as_user sh -c 'command -v brew' 2>/dev/null || true)" /opt/homebrew/bin/brew /usr/local/bin/brew; do
		if [ -n "$b" ] && [ -x "$b" ]; then
			echo "$b"
			return 0
		fi
	done
	return 1
}

# Homebrew's tailcat first (GitHub releases have no macOS build). A binary
# passed with --tailcat (e.g. cross-built from a release tag) is checked and
# copied into the agent folder so the service never depends on a download.
find_tailcat() {
	local brew got
	if [ -n "$TAILCAT_SRC" ]; then
		[ -f "$TAILCAT_SRC" ] || die "not found: $TAILCAT_SRC"
		if [ -n "$TAILCAT_SHA" ]; then
			got=$(shasum -a 256 "$TAILCAT_SRC" | awk '{print $1}')
			[ "$got" = "$TAILCAT_SHA" ] || die "checksum mismatch for $TAILCAT_SRC (got $got)"
		fi
		TAILCAT_BIN=$DIR/bin/tailcat
		as_user mkdir -p "$DIR/bin"
		# shellcheck disable=SC2016 # $1 and $2 are expanded by the inner sh
		as_user sh -c 'cat "$1" > "$2" && chmod 755 "$2"' sh "$TAILCAT_SRC" "$TAILCAT_BIN"
		xattr -c "$TAILCAT_BIN" 2>/dev/null || true
		return
	fi
	if brew=$(brew_bin); then
		if ! as_user "$brew" list tailcat >/dev/null 2>&1; then
			log "installing tailcat with Homebrew"
			as_user "$brew" install tailcat
		fi
		TAILCAT_BIN=$(as_user "$brew" --prefix)/bin/tailcat
	else
		local c
		for c in "$(command -v tailcat 2>/dev/null || true)" /usr/local/bin/tailcat "$THOME/go/bin/tailcat" "$DIR/bin/tailcat"; do
			if [ -n "$c" ] && [ -x "$c" ]; then
				TAILCAT_BIN=$c
				break
			fi
		done
	fi
	[ -n "$TAILCAT_BIN" ] && [ -x "$TAILCAT_BIN" ] ||
		die "tailcat not found: install Homebrew and rerun, or pass --tailcat PATH"
}

xml_escape() {
	printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

write_plist() {
	local out=$1 allow args=() a path
	allow=$(IFS=,; echo "${NODEKEYS[*]}")
	for a in "$TAILCAT_BIN" serve "--key=$KEY" "--allow=$allow" "--ssh-authorized-keys=$DIR/authorized_keys" ssh; do
		args+=("		<string>$(xml_escape "$a")</string>")
	done
	path="$(dirname "$TAILCAT_BIN"):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
	cat >"$out" <<EOF
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
		<key>PATH</key>
		<string>$(xml_escape "$path")</string>
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
	plutil -lint "$out" >/dev/null || die "generated plist is invalid: $out"
}

do_install() {
	[ ${#NODEKEYS[@]} -gt 0 ] || die "--client-nodekey is required (the agent's tailcat client key; without it any client could connect)"
	local k
	for k in "${NODEKEYS[@]}"; do
		case "$k" in nodekey:*) ;; *) die "client keys look like nodekey:<hex>, got: $k" ;; esac
	done
	[ ${#PUBKEYS[@]} -gt 0 ] || [ -n "$PUBKEYS_FILE" ] || [ -s "$DIR/authorized_keys" ] ||
		die "--authorized-key or --authorized-keys-file is required"

	log "1/3 tailcat and keys"
	as_user mkdir -p "$DIR"
	as_user chmod 700 "$DIR"
	find_tailcat
	"$TAILCAT_BIN" --version | sed 's/^/agent-tether: tailcat /'

	if [ ${#PUBKEYS[@]} -gt 0 ] || [ -n "$PUBKEYS_FILE" ]; then
		{
			if [ ${#PUBKEYS[@]} -gt 0 ]; then printf '%s\n' "${PUBKEYS[@]}"; fi
			if [ -n "$PUBKEYS_FILE" ]; then cat "$PUBKEYS_FILE"; fi
		} | write_as_user "$DIR/authorized_keys"
	fi
	if [ -s "$KEY" ]; then
		log "keeping the existing server key and address"
	else
		as_user "$TAILCAT_BIN" genkey --key="$KEY" --fixed-region | write_as_user "$DIR/address"
		log "created server key $KEY"
	fi

	log "2/3 LaunchDaemon $SERVICE (needs your password once)"
	local tmp
	tmp=$(mktemp)
	write_plist "$tmp"
	chmod 644 "$tmp"
	as_root launchctl bootout "system/$SERVICE" 2>/dev/null || true
	as_root install -m 0644 -o root -g wheel "$tmp" "$PLIST"
	rm -f "$tmp"
	as_root launchctl enable "system/$SERVICE"
	as_root launchctl bootstrap system "$PLIST"
	log "installed and started $PLIST"

	if [ "$PRIVILEGED" -eq 1 ]; then
		tmp=$(mktemp)
		printf '# agent-tether: lets %s run sudo without a password. Remove this file to revoke.\n%s ALL=(ALL) NOPASSWD: ALL\n' "$TUSER" "$TUSER" >"$tmp"
		if visudo -cf "$tmp" >/dev/null; then
			as_root mkdir -p /etc/sudoers.d
			as_root install -m 0440 -o root -g wheel "$tmp" "$SUDOERS"
			log "installed $SUDOERS (passwordless sudo for $TUSER)"
		else
			log "warning: sudoers check failed; continuing unprivileged"
		fi
		rm -f "$tmp"
	fi

	if [ "$STAY_AWAKE" -eq 1 ]; then
		local prev
		prev=$(pmset -g custom | awk '/^AC Power:/{ac=1; next} /^[A-Za-z].*:$/{ac=0} ac && $1=="sleep"{print $2}')
		if [ ! -s "$DIR/stay-awake-by-installer" ]; then
			printf '%s\n' "${prev:-1}" | write_as_user "$DIR/stay-awake-by-installer"
		fi
		as_root pmset -c sleep 0
		log "system sleep on AC power disabled (was: ${prev:-unknown})"
	fi

	sleep 3
	log "3/3 status"
	do_status
	echo
	log "Full Disk Access (optional): without it the shell cannot open Desktop, Documents"
	log "or Downloads. In System Settings > Privacy & Security > Full Disk Access, add"
	log "$(readlink -f "$TAILCAT_BIN" 2>/dev/null || echo "$TAILCAT_BIN") and switch it on."
	log "A Homebrew upgrade moves that file, so the switch may need turning on again."
	if [ "$OPEN_SETTINGS" -eq 1 ] && [ "$IS_ROOT" -eq 0 ]; then
		open -R "$(readlink -f "$TAILCAT_BIN" 2>/dev/null || echo "$TAILCAT_BIN")" || true
		open "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles" || true
	fi
}

do_status() {
	local addr="" state
	[ -s "$DIR/address" ] && addr=$(tr -d '\r\n' <"$DIR/address")
	# launchctl print on a system service needs root; without a cached sudo
	# login, status says so instead of asking for the password.
	if [ "$IS_ROOT" -eq 1 ]; then
		state=$(launchctl print "system/$SERVICE" 2>/dev/null | awk -F' = ' '/^\tstate = /{print $2; exit}')
	elif sudo -n true 2>/dev/null; then
		state=$(sudo -n launchctl print "system/$SERVICE" 2>/dev/null | awk -F' = ' '/^\tstate = /{print $2; exit}')
	else
		state="unknown (run with sudo to see it)"
	fi
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
	if [ -e "$SUDOERS" ]; then as_root rm -f "$SUDOERS" && log "removed $SUDOERS"; fi
	if [ -s "$DIR/stay-awake-by-installer" ]; then
		as_root pmset -c sleep "$(head -n1 "$DIR/stay-awake-by-installer")" && log "restored AC sleep setting"
	fi
	if [ -e "$KEY" ] && [ "${KEY#"$DIR"/}" = "$KEY" ]; then
		as_user rm -f "$KEY" && log "deleted $KEY"
	fi
	as_user rm -rf "$DIR"
	as_root rm -f "$PLIST"
	log "removed $PLIST and $DIR"
	log "stopping $SERVICE; an agent connected through it is disconnected now"
	log "uninstall finished $(date)"
	# Last step: bootout ends any session that runs through the service.
	as_root launchctl bootout "system/$SERVICE" 2>/dev/null || true
}

case "$ACTION" in
install) do_install ;;
status) do_status ;;
uninstall) do_uninstall ;;
*) sed -n '2,29p' "$0" 2>/dev/null || true; die "usage: install-macos.sh install|status|uninstall [options]" ;;
esac

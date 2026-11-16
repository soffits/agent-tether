#!/usr/bin/env bash
# agent-tether target installer for Linux (systemd).
# Runs `tailcat serve ... ssh` as a systemd user service with lingering
# enabled, so the machine is reachable from boot, before anyone logs in.
#
#   install-linux.sh install   --client-nodekey nodekey:... --authorized-key "ssh-ed25519 AAAA..." [options]
#   install-linux.sh status    [options]
#   install-linux.sh uninstall [options] [--detach]
#
# Run it as the target user, or as root with --user <name> (the elevated
# bootstrap session is root). Options:
#   --user NAME               account the service runs as (default: the current user)
#   --service NAME            systemd unit name (default: agent-tether)
#   --dir PATH                agent files (default: ~<user>/.config/agent-tether)
#   --key NAME|PATH           tailcat server key (default: <dir>/server.private.json)
#   --client-nodekey KEY      the agent's tailcat client key, for --allow (repeatable)
#   --authorized-key LINE     the agent's SSH public key line (repeatable)
#   --authorized-keys-file F  copy SSH public keys from a file instead
#   --tailcat PATH            tailcat binary (default: found on PATH)
#   --privileged              let the user run sudo without a password (sudoers drop-in)
#   --stay-awake              mask the systemd sleep targets so the machine never suspends
#   --detach                  uninstall: run from a separate transient unit after 5 s
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
DETACH=0
ORIG_ARGS=("$@")

die() { echo "install-linux: $*" >&2; exit 1; }
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
	--detach) DETACH=1; shift ;;
	*) die "unknown option: $1" ;;
	esac
done

case "$SERVICE" in *[!A-Za-z0-9_.-]* | "") die "--service may only use letters, digits, . _ -" ;; esac

IS_ROOT=0
[ "$(id -u)" -eq 0 ] && IS_ROOT=1
if [ -z "$TUSER" ]; then
	[ "$IS_ROOT" -eq 1 ] && die "running as root: pass --user <name> for the account the service should run as"
	TUSER=$(id -un)
fi
id "$TUSER" >/dev/null 2>&1 || die "no such user: $TUSER"
TUID=$(id -u "$TUSER")
THOME=$(getent passwd "$TUSER" | cut -d: -f6)
[ -n "$THOME" ] || die "cannot find the home directory of $TUSER"
[ "$IS_ROOT" -eq 1 ] || [ "$TUID" -eq "$(id -u)" ] || die "run as $TUSER or as root"

DIR=${DIR:-$THOME/.config/agent-tether}
KEY=${KEY:-$DIR/server.private.json}
UNIT_DIR=$THOME/.config/systemd/user
UNIT=$UNIT_DIR/$SERVICE.service
SUDOERS=/etc/sudoers.d/$SERVICE
RUNTIME=/run/user/$TUID
LOGFILE=$THOME/$SERVICE-uninstall.log
SLEEP_TARGETS=(sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target)

# Run a command as the target user.
as_user() {
	if [ "$(id -u)" -eq "$TUID" ]; then
		"$@"
	elif command -v runuser >/dev/null 2>&1; then
		runuser -u "$TUSER" -- env HOME="$THOME" "$@"
	else
		sudo -H -u "$TUSER" -- "$@"
	fi
}

# Write stdin to a file owned by the target user, mode 600.
write_as_user() {
	# shellcheck disable=SC2016 # $1 is expanded by the inner sh
	as_user sh -c 'umask 077; cat > "$1"' sh "$1"
}

# systemctl --user for the target user, also from SSH or root where the
# session environment is missing.
user_systemctl() {
	as_user env XDG_RUNTIME_DIR="$RUNTIME" DBUS_SESSION_BUS_ADDRESS="unix:path=$RUNTIME/bus" systemctl --user "$@"
}

# Run a command as root: directly, or with passwordless sudo if available.
as_root() {
	if [ "$IS_ROOT" -eq 1 ]; then
		"$@"
	elif sudo -n true 2>/dev/null; then
		sudo -n "$@"
	else
		return 1
	fi
}

key_is_path() { case "$KEY" in */*) return 0 ;; *) return 1 ;; esac; }

find_tailcat() {
	if [ -n "$TAILCAT_BIN" ]; then
		[ -x "$TAILCAT_BIN" ] || die "not executable: $TAILCAT_BIN"
		return
	fi
	local c
	for c in "$(command -v tailcat 2>/dev/null || true)" /usr/bin/tailcat /usr/local/bin/tailcat "$THOME/.local/bin/tailcat" "$THOME/go/bin/tailcat"; do
		if [ -n "$c" ] && [ -x "$c" ]; then
			# Keep the path as found: version-manager shims (mise, asdf) are
			# symlinks that break when resolved.
			TAILCAT_BIN=$c
			break
		fi
	done
	[ -n "$TAILCAT_BIN" ] || die "tailcat not found; install it first (see https://github.com/tailscale/tailcat/blob/main/INSTALL.md) or pass --tailcat PATH"
	case "$TAILCAT_BIN" in /snap/*) log "warning: snap tailcat is strictly confined; a release binary or distro package is more predictable for a service" ;; esac
}

need_systemd() {
	[ -d /run/systemd/system ] || die "systemd is not running on this machine; this installer only supports systemd (use a release binary with your init system's own service format)"
	command -v systemctl >/dev/null || die "systemctl not found"
}

wait_for_user_bus() {
	local _
	for _ in $(seq 1 20); do
		[ -S "$RUNTIME/bus" ] && return 0
		sleep 0.5
	done
	return 1
}

do_install() {
	need_systemd
	find_tailcat
	[ ${#NODEKEYS[@]} -gt 0 ] || die "--client-nodekey is required (the agent's tailcat client key; without it any client could connect)"
	local k
	for k in "${NODEKEYS[@]}"; do
		case "$k" in nodekey:*) ;; *) die "client keys look like nodekey:<hex>, got: $k" ;; esac
	done
	[ ${#PUBKEYS[@]} -gt 0 ] || [ -n "$PUBKEYS_FILE" ] || [ -s "$DIR/authorized_keys" ] ||
		die "--authorized-key or --authorized-keys-file is required"

	as_user mkdir -p "$DIR" "$UNIT_DIR"
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

	local allow
	allow=$(IFS=,; echo "${NODEKEYS[*]}")
	write_as_user "$UNIT" <<EOF
[Unit]
Description=Agent remote access (tailcat SSH)
After=network-online.target
Wants=network-online.target

[Service]
Environment="TAILCAT_ADDR_FILE=$DIR/address"
ExecStart="$TAILCAT_BIN" serve "--key=$KEY" "--allow=$allow" "--ssh-authorized-keys=$DIR/authorized_keys" ssh
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
EOF
	log "wrote $UNIT"

	# Linger starts the user's service manager at boot, without a login.
	if [ "$(loginctl show-user "$TUSER" --property=Linger --value 2>/dev/null || true)" != yes ]; then
		if as_root loginctl enable-linger "$TUSER" 2>/dev/null || loginctl enable-linger "$TUSER" 2>/dev/null; then
			as_user touch "$DIR/linger-enabled-by-installer"
			log "enabled lingering for $TUSER"
		else
			log "warning: could not enable lingering; the service will only run while $TUSER is logged in."
			log "         fix once with: sudo loginctl enable-linger $TUSER"
		fi
	fi
	wait_for_user_bus || die "the user service manager for $TUSER is not running ($RUNTIME/bus missing); log in once or enable lingering, then rerun"

	user_systemctl daemon-reload
	user_systemctl enable "$SERVICE.service" >/dev/null
	user_systemctl restart "$SERVICE.service"
	log "service $SERVICE enabled and started"

	if [ "$PRIVILEGED" -eq 1 ]; then
		local tmp
		tmp=$(mktemp)
		printf '# agent-tether: lets %s run sudo without a password. Remove this file to revoke.\n%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$TUSER" "$TUSER" >"$tmp"
		if visudo -cf "$tmp" >/dev/null && as_root install -m 0440 -o root -g root "$tmp" "$SUDOERS"; then
			log "installed $SUDOERS (passwordless sudo for $TUSER)"
		else
			log "warning: could not install $SUDOERS (needs root); continuing unprivileged"
		fi
		rm -f "$tmp"
	fi

	if [ "$STAY_AWAKE" -eq 1 ]; then
		if as_root systemctl mask "${SLEEP_TARGETS[@]}" >/dev/null 2>&1; then
			as_user touch "$DIR/stay-awake-by-installer"
			log "masked sleep targets; this machine will not suspend"
		else
			log "warning: masking sleep targets needs root; skipped"
		fi
	fi

	sleep 3
	do_status
}

do_status() {
	local addr="" state enabled linger
	[ -s "$DIR/address" ] && addr=$(tr -d '\r\n' <"$DIR/address")
	state=$(user_systemctl is-active "$SERVICE.service" 2>/dev/null || true)
	enabled=$(user_systemctl is-enabled "$SERVICE.service" 2>/dev/null || true)
	linger=$(loginctl show-user "$TUSER" --property=Linger --value 2>/dev/null || echo unknown)
	echo "SERVICE=$SERVICE"
	echo "USER=$TUSER"
	echo "ACTIVE=${state:-unknown}"
	echo "ENABLED=${enabled:-unknown}"
	echo "LINGER=${linger:-no}"
	echo "DIR=$DIR"
	echo "PRIVILEGED=$([ -e "$SUDOERS" ] && echo yes || echo no)"
	echo "STAY_AWAKE=$([ -e "$DIR/stay-awake-by-installer" ] && echo yes || echo no)"
	echo "ADDRESS=$addr"
}

do_uninstall() {
	if [ "$DETACH" -eq 1 ]; then
		local self copy args=()
		self=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)
		[ -n "$self" ] && [ -f "$self" ] || die "--detach needs the script as a file (copy it over first, then run it with bash <file>)"
		copy=$(mktemp /tmp/agent-tether-uninstall.XXXXXX)
		cp "$self" "$copy"
		chmod 755 "$copy"
		local a
		for a in "${ORIG_ARGS[@]}"; do [ "$a" = --detach ] || args+=("$a"); done
		[ "$IS_ROOT" -eq 1 ] && chown "$TUSER" "$copy"
		# A transient unit of its own survives the service being stopped; a plain
		# background process would be killed with the service's cgroup.
		user_systemctl --version >/dev/null
		as_user env XDG_RUNTIME_DIR="$RUNTIME" DBUS_SESSION_BUS_ADDRESS="unix:path=$RUNTIME/bus" \
			systemd-run --user --collect --unit="$SERVICE-uninstall" --on-active=5 \
			/bin/bash "$copy" uninstall "${args[@]}"
		log "uninstall scheduled in 5 seconds; this connection will drop. Log: $LOGFILE"
		return
	fi

	exec > >(tee -a "$LOGFILE") 2>&1
	log "uninstall started $(date)"

	if [ -e "$SUDOERS" ]; then
		if as_root rm -f "$SUDOERS"; then log "removed $SUDOERS"; else log "could not remove $SUDOERS (needs root): sudo rm $SUDOERS"; fi
	fi
	if [ -e "$DIR/stay-awake-by-installer" ]; then
		if as_root systemctl unmask "${SLEEP_TARGETS[@]}" >/dev/null 2>&1; then log "unmasked sleep targets"; else log "could not unmask sleep targets (needs root): sudo systemctl unmask ${SLEEP_TARGETS[*]}"; fi
	fi
	if [ -e "$DIR/linger-enabled-by-installer" ]; then
		if as_root loginctl disable-linger "$TUSER" 2>/dev/null || loginctl disable-linger "$TUSER" 2>/dev/null; then log "disabled lingering"; else log "lingering left on: sudo loginctl disable-linger $TUSER"; fi
	fi
	if ! key_is_path; then
		find_tailcat
		as_user "$TAILCAT_BIN" genkey --delete --key="$KEY" >/dev/null 2>&1 && log "deleted tailcat key $KEY"
	elif [ -e "$KEY" ] && [ "${KEY#"$DIR"/}" = "$KEY" ]; then
		as_user rm -f "$KEY" && log "deleted $KEY"
	fi
	user_systemctl disable "$SERVICE.service" >/dev/null 2>&1 || true
	as_user rm -f "$UNIT"
	as_user rm -rf "$DIR"
	log "removed $UNIT and $DIR"
	user_systemctl daemon-reload 2>/dev/null || true
	log "stopping $SERVICE; an agent connected through it is disconnected now"
	log "uninstall finished $(date)"
	# Last step: stopping the service ends any session that runs through it.
	case "$0" in /tmp/agent-tether-uninstall.*) rm -f "$0" ;; esac
	user_systemctl stop "$SERVICE.service" 2>/dev/null || true
}

case "$ACTION" in
install) do_install ;;
status) do_status ;;
uninstall) do_uninstall ;;
*) sed -n '2,24p' "$0" 2>/dev/null || true; die "usage: install-linux.sh install|status|uninstall [options]" ;;
esac

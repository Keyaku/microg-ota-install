#!/usr/bin/env bash
#
# flash-microg.sh
#
# One-shot flasher for the microG OTA package. Detects a connected device
# (prompting when more than one is present), downloads the latest release zip
# into a cache directory, then sideloads it and reboots.
#
# Designed to be run either from a clone:
#
#     ./flash-microg.sh
#
# or straight off GitHub, without cloning:
#
#     curl -fsSL https://raw.githubusercontent.com/Keyaku/microg-ota-install/main/flash-microg.sh | bash
#
# When piped into bash, the script's stdin is the pipe (not the terminal), so
# every interactive prompt reads from /dev/tty explicitly. If no terminal is
# available, the script falls back to non-interactive defaults where it can and
# aborts where a human decision is required.
#
# Requires: adb, curl. (jq is used when present, but is not required.)

set -euo pipefail

# --- config ---------------------------------------------------------------
REPO="Keyaku/microg-ota-install"
API_URL="https://api.github.com/repos/$REPO/releases/latest"
# Release asset we want: the version-stamped installer (not the uninstaller).
ASSET_RE='microg-ota-product-[^"]*\.zip'
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/microg-ota-install"

# How long to wait (seconds) for a device to enter a given adb state. These are
# overridable from the environment, so a slower device can bump them without
# editing the script — e.g. on the `curl | bash` route:
#
#     curl -fsSL <url> | WAIT_SIDELOAD=90 WAIT_RECOVERY=90 bash
#
WAIT_SIDELOAD="${WAIT_SIDELOAD:-30}"
WAIT_RECOVERY="${WAIT_RECOVERY:-30}"
WAIT_DEVICE="${WAIT_DEVICE:-90}"

# --- terminal for interactive prompts (works under `curl | bash`) ---------
if [ -r /dev/tty ] && [ -w /dev/tty ]; then
	TTY=/dev/tty
else
	TTY=""
fi

# --- pretty output --------------------------------------------------------
if [ -t 2 ]; then
	c_reset=$'\033[0m'; c_bold=$'\033[1m'
	c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_blu=$'\033[34m'
else
	c_reset=""; c_bold=""; c_red=""; c_grn=""; c_yel=""; c_blu=""
fi

log()  { printf '%s>>%s %s\n'  "$c_blu$c_bold" "$c_reset" "$*" >&2; }
ok()   { printf '%s✓%s %s\n'   "$c_grn$c_bold" "$c_reset" "$*" >&2; }
warn() { printf '%s!%s %s\n'   "$c_yel$c_bold" "$c_reset" "$*" >&2; }
die()  { printf '%sERROR:%s %s\n' "$c_red$c_bold" "$c_reset" "$*" >&2; exit 1; }

# Read a line of input from the terminal. $1 = prompt, echoes into stderr.
# Returns non-zero (and empty answer) when no terminal is available.
ANSWER=""
ask() {
	ANSWER=""
	[ -n "$TTY" ] || return 1
	printf '%s%s%s ' "$c_bold" "$1" "$c_reset" >/dev/tty
	IFS= read -r ANSWER <"$TTY" || return 1
	return 0
}

# Wait for the user to press ENTER (no-op when non-interactive).
pause() {
	[ -n "$TTY" ] || return 0
	printf '%s%s%s' "$c_bold" "${1:-Press ENTER to continue...}" "$c_reset" >/dev/tty
	IFS= read -r _ <"$TTY" || true
}

# --- dependencies ---------------------------------------------------------
command -v adb  >/dev/null 2>&1 || die "missing dependency: adb (install the Android platform-tools)"
command -v curl >/dev/null 2>&1 || die "missing dependency: curl"

# --- adb helpers ----------------------------------------------------------
# Print "<serial> <state>" for every attached device/emulator. States seen
# here: device, recovery, sideload, unauthorized, offline.
adb_list() {
	adb devices | awk 'NR>1 && NF>=2 {print $1, $2}'
}

# Serials currently in a given state (one per line).
serials_in_state() {
	adb_list | awk -v s="$1" '$2==s {print $1}'
}

# Suggest bumping the relevant timeout variable when a wait runs out. $1 = the
# adb state we were waiting for; maps it to the env var that controls its wait.
timeout_hint() {
	local var
	case "$1" in
		sideload) var="WAIT_SIDELOAD" ;;
		recovery) var="WAIT_RECOVERY" ;;
		device)   var="WAIT_DEVICE" ;;
		*)        return 0 ;;
	esac
	warn "If the ${1} wait (\$$var=${!var}s) is too low for your device, increase it:"
	warn "  $var=<seconds> $0        (or, piped:  curl … | $var=<seconds> bash)"
}

# Wait until $1 (serial) reaches state $2, or timeout $3 seconds. Prints a
# spinner-ish countdown to stderr. Returns 0 on success, 1 on timeout (with a
# hint on which timeout variable to raise).
wait_for_state() {
	local serial="$1" want="$2" timeout="$3" waited=0 state
	while [ "$waited" -lt "$timeout" ]; do
		state="$(adb_list | awk -v d="$serial" '$1==d {print $2}')"
		[ "$state" = "$want" ] && { printf '\n' >&2; return 0; }
		printf '\r   waiting for %s to enter "%s" state... %ds ' "$serial" "$want" "$waited" >&2
		sleep 2
		waited=$((waited + 2))
	done
	printf '\n' >&2
	timeout_hint "$want"
	return 1
}

# --- 1. device selection --------------------------------------------------
log "Starting adb server..."
adb start-server >/dev/null 2>&1 || true

select_device() {
	local -a serials states
	local line serial state
	while IFS=' ' read -r serial state; do
		[ -n "$serial" ] || continue
		serials+=("$serial")
		states+=("$state")
	done < <(adb_list)

	# No device yet: wait for one to show up (device may just be unplugged).
	if [ "${#serials[@]}" -eq 0 ]; then
		warn "No device detected. Connect your device via USB and enable USB debugging."
		log "Waiting up to ${WAIT_DEVICE}s for a device..."
		local waited=0
		while [ "$waited" -lt "$WAIT_DEVICE" ]; do
			if [ -n "$(adb_list)" ]; then break; fi
			printf '\r   waiting for a device... %ds ' "$waited" >&2
			sleep 2; waited=$((waited + 2))
		done
		printf '\n' >&2
		serials=(); states=()
		while IFS=' ' read -r serial state; do
			[ -n "$serial" ] || continue
			serials+=("$serial"); states+=("$state")
		done < <(adb_list)
		[ "${#serials[@]}" -gt 0 ] || { timeout_hint device; die "no device detected."; }
	fi

	# Flag unauthorized/offline so the user knows to fix them.
	local i
	for i in "${!serials[@]}"; do
		case "${states[$i]}" in
			unauthorized) warn "${serials[$i]} is unauthorized — accept the RSA prompt on the device." ;;
			offline)      warn "${serials[$i]} is offline — reconnect it." ;;
		esac
	done

	# Single device: use it outright.
	if [ "${#serials[@]}" -eq 1 ]; then
		SERIAL="${serials[0]}"
		return 0
	fi

	# Multiple devices: interactive picker (needs a terminal).
	if [ -z "$TTY" ]; then
		die "multiple devices attached and no terminal to prompt on. Set ANDROID_SERIAL or run interactively."
	fi

	printf '\n%sMultiple devices found:%s\n' "$c_bold" "$c_reset" >&2
	for i in "${!serials[@]}"; do
		local model=""
		if [ "${states[$i]}" = "device" ]; then
			model="$(adb -s "${serials[$i]}" shell getprop ro.product.model 2>/dev/null | tr -d '\r')"
		fi
		printf '  %s[%d]%s %s  (%s)%s\n' \
			"$c_bold" "$((i + 1))" "$c_reset" "${serials[$i]}" "${states[$i]}" \
			"${model:+  ${model}}" >&2
	done

	local choice
	while :; do
		ask "Select a device [1-${#serials[@]}]:" || die "no selection made."
		choice="$ANSWER"
		if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#serials[@]}" ]; then
			SERIAL="${serials[$((choice - 1))]}"
			return 0
		fi
		warn "Invalid selection: '$choice'"
	done
}

SERIAL="${ANDROID_SERIAL:-}"
if [ -n "$SERIAL" ]; then
	log "Using device from ANDROID_SERIAL: $SERIAL"
else
	select_device
fi
ok "Device: $SERIAL"

# Convenience wrapper: always target the chosen serial.
adbd() { adb -s "$SERIAL" "$@"; }

# --- 2. download the latest release zip -----------------------------------
download_release() {
	log "Querying latest release of $REPO ..."
	local meta url name
	local -a auth=()
	[ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")

	meta="$(curl -fsSL "${auth[@]}" -H "Accept: application/vnd.github+json" "$API_URL")" \
		|| die "failed to query the GitHub API."

	if command -v jq >/dev/null 2>&1; then
		url="$(printf '%s' "$meta" | jq -r \
			'.assets[] | select(.name | test("^microg-ota-product-.*\\.zip$")) | .browser_download_url' \
			| head -n1)"
	else
		url="$(printf '%s' "$meta" \
			| grep -o "\"browser_download_url\": *\"[^\"]*$ASSET_RE\"" \
			| head -n1 | sed -E 's/.*"(https[^"]+)".*/\1/')"
	fi
	[ -n "$url" ] || die "could not find a microg-ota-product-*.zip asset in the latest release."

	name="$(basename "$url")"
	mkdir -p "$CACHE_DIR"
	ZIP="$CACHE_DIR/$name"

	if [ -f "$ZIP" ]; then
		ok "Already cached: $ZIP"
		return 0
	fi

	log "Downloading $name ..."
	curl -fL --progress-bar "${auth[@]}" -o "$ZIP.part" "$url" || { rm -f "$ZIP.part"; die "download failed."; }
	mv "$ZIP.part" "$ZIP"
	ok "Downloaded: $ZIP"
}

ZIP=""
download_release

# --- 3/4. sideload --------------------------------------------------------
# Run the actual `adb sideload`. On failure, let the user retry / bail / reboot.
do_sideload() {
	log "Sideloading $(basename "$ZIP") ..."
	if adbd sideload "$ZIP"; then
		ok "Sideload completed."
		return 0
	fi

	# `adb sideload` can report a non-zero exit even on a successful flash
	# (the device closes the connection as it finishes). Let the user decide.
	warn "adb sideload reported an error. This is sometimes spurious — check the device screen."
	while :; do
		ask "Choose: [r]etry sideload, [c]ontinue (reboot anyway), [a]bort?" || return 1
		case "${ANSWER,,}" in
			r|retry)    adbd sideload "$ZIP" && { ok "Sideload completed."; return 0; } || warn "Still failing." ;;
			c|continue) return 0 ;;
			a|abort)    die "aborted by user; leaving the device in its current state." ;;
			*)          warn "Please answer r, c, or a." ;;
		esac
	done
}

# Try the direct route first: `adb reboot sideload-auto-reboot` boots straight
# into the sideload state AND makes the device reboot to system on its own once
# the package is applied, on devices whose recovery supports it (most LineageOS
# builds). The auto-reboot variant matters because a plain post-flash
# `adb reboot` does not reliably land from some recoveries' sideload-done state.
try_direct_sideload() {
	log "Rebooting to sideload (auto-reboot)..."
	adbd reboot sideload-auto-reboot 2>/dev/null || return 1
	wait_for_state "$SERIAL" sideload "$WAIT_SIDELOAD"
}

# Fallback: boot to the recovery menu and walk the user through enabling
# "Apply update from ADB", then wait for the sideload state (or an ENTER).
recovery_sideload() {
	log "Direct sideload not available — rebooting to recovery instead."
	adbd reboot recovery 2>/dev/null || die "could not reboot to recovery."

	if ! wait_for_state "$SERIAL" recovery "$WAIT_RECOVERY"; then
		# Some recoveries jump straight to sideload; check before giving up.
		if [ "$(adb_list | awk -v d="$SERIAL" '$1==d {print $2}')" = "sideload" ]; then
			return 0
		fi
		warn "Device did not report a recovery state in time; continuing anyway."
	fi

	printf '\n%sOn the device, select "Apply update from ADB" (a.k.a. "ADB sideload").%s\n' \
		"$c_yel$c_bold" "$c_reset" >&2

	# Prefer auto-detecting the sideload state; fall back to a manual ENTER.
	log "Waiting for the device to enter sideload mode..."
	if wait_for_state "$SERIAL" sideload "$WAIT_SIDELOAD"; then
		return 0
	fi

	if [ -n "$TTY" ]; then
		warn "Could not auto-detect sideload mode."
		pause "Once the device shows 'Now send the package...', press ENTER to flash..."
		return 0
	fi
	die "device never entered sideload mode and no terminal is available to prompt."
}

flash() {
	# The direct route uses sideload-auto-reboot, so the device reboots itself
	# after applying; the recovery fallback does not, so we reboot from here.
	local auto_reboot=0
	if try_direct_sideload; then
		ok "Device is in sideload mode."
		auto_reboot=1
	else
		recovery_sideload
	fi

	do_sideload || die "flashing failed."

	if [ "$auto_reboot" -eq 1 ]; then
		ok "Flashed. The device will reboot to system on its own."
	else
		log "Rebooting to system..."
		adbd reboot 2>/dev/null || warn "Could not send reboot; select 'Reboot system now' on the device."
		ok "Done."
	fi
	ok "microG should be up after the device finishes booting."
}

flash

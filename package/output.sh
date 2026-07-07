# output.sh -- console/UI layer: bootmode detection, printing, prompts.
# Sourced by recovery-tools.sh. Must come first: everything else calls ui_print.

# General shell convenience aliases (interactive/debug use).
alias ll='ls -lh'
alias la='ls -lAh'

# Are we running inside a booted system (app/adb) rather than recovery?
ps | grep zygote | grep -v grep >/dev/null && bootmode=true || bootmode=false
$bootmode || ps -A 2>/dev/null | grep zygote | grep -v grep >/dev/null && bootmode=true
[ "$BOOTMODE" = true ] && bootmode=true

if $bootmode; then
	ui_print() {
		echo "$1" >&3
	}
elif [ -e "$outfd" ]; then
	ui_print() {
		echo "ui_print $1" >> "$outfd"
		echo "ui_print" >> "$outfd"
	}
else
	ui_print() {
		echo "$1"
	}
fi

log() { echo "$1"; }

center_text() {
	local width=$1
	local text="$2"
	local text_len=${#text}
	[ $width -le $text_len ] && width=$text_len

	# Calculate padding
	local total_padding=$((width - text_len))
	local left_padding=$((total_padding / 2))
	local right_padding=$((total_padding - left_padding))

	# Print with both left and right padding
	printf '%*s%s%*s\n' $left_padding '' "$text" $right_padding ''
}

# Yes/no prompt driven by the hardware volume keys, for use inside recovery:
#   Vol Up   = yes -> return 0
#   Vol Down = no  -> return 1
# Falls back to the default answer ($2: "yes"/"no", default "no") when running
# in bootmode or when getevent is unavailable, so non-interactive contexts
# (adb sideload from a booted system, headless installs) never hang waiting on
# a keypress that can't come.
#
# Usage:
#   if prompt_yn "Reboot to recovery now?" no; then ... ; fi
prompt_yn() {
	local question="$1" default="${2:-no}" key
	ui_print " "
	ui_print "$question"
	if $bootmode || ! command -v getevent >/dev/null 2>&1; then
		case "$default" in
			y*|Y*) ui_print "(no keys available -- assuming YES)"; return 0 ;;
			*)     ui_print "(no keys available -- assuming NO)";  return 1 ;;
		esac
	fi
	ui_print "  Vol Up = YES   |   Vol Down = NO"
	while true; do
		# One event at a time; -q hides the device listing, -l prints symbolic
		# names. Non-key events (EV_SYN/EV_ABS) match nothing and we loop again.
		key="$(getevent -qlc 1 2>/dev/null | grep -oE -m1 'KEY_VOLUME(UP|DOWN)')"
		case "$key" in
			KEY_VOLUMEUP)   ui_print "  -> YES"; return 0 ;;
			KEY_VOLUMEDOWN) ui_print "  -> NO";  return 1 ;;
		esac
	done
}

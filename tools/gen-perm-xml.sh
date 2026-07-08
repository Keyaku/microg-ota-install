#!/usr/bin/env bash
#
# gen-perm-xml.sh
#
# Regenerates the flashable package's privapp-permissions XML from the actual
# APK(s) being shipped, so the grants never drift out of sync with what
# GmsCore/GmsCompanion request or with how a given Android release classifies
# each permission. Writes privapp-permissions-<pkg>.xml -> etc/permissions/.
#
# The allow-list is emitted digest-less (matched by package name only) -- the
# form with a long track record on ROMs with ro.control_privapp_permissions=
# enforce. default-permissions (dangerous-perm auto-grants -> etc/default-
# permissions/) are an addition on top of that baseline and are only emitted
# with --default-permissions.
#
# This wrapper (part of this repo, MIT-licensed) is a thin orchestrator around
# two THIRD-PARTY tools authored by ale5000, DOWNLOADED at run time from the
# upstream microg-unofficial-installer project rather than vendored, so upstream
# fixes are picked up automatically:
#   - dl-perm-list.sh      builds the AOSP permission database
#   - generate-perm-xml.sh reads an APK + the DB and emits the XML
# Those two are GPL-3.0-or-later OR Apache-2.0. See tools/THIRD_PARTY.md.
#
# Usage:
#   tools/gen-perm-xml.sh [options] APK [APK...]
#     --dest DIR              privapp-permissions output dir
#                             (default: package/product/etc/permissions/)
#     --def-dest DIR          default-permissions output dir
#                             (default: package/product/etc/default-permissions/)
#     --default-permissions   also emit default-permissions (off by default)
#     --refresh               force re-download of the upstream tools AND the DB
#
# Env overrides:
#   UPSTREAM_REPO   default: micro5k/microg-unofficial-installer
#   UPSTREAM_REF    default: main   (pin to a tag/commit for reproducible builds)
#   AAPT_PATH
#
# Requires: curl + aapt2/aapt (Android SDK build-tools). The upstream generator
# also needs apksigner or keytool (auto-detected) to run, even though the digest
# it produces is stripped from the output.
# Caches live under ${XDG_CACHE_HOME:-~/.cache}/microg-ota-install/.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CACHE_BASE="${XDG_CACHE_HOME:-$HOME/.cache}/microg-ota-install"
TOOLS_CACHE="$CACHE_BASE/upstream-tools"
PERMDB_DIR="$CACHE_BASE/perm-db"

DEST_DIR="$REPO_ROOT/package/product/etc/permissions"
DEF_DEST_DIR="$REPO_ROOT/package/product/etc/default-permissions"
REFRESH=0
# default-permissions (dangerous-perm auto-grants) are an addition on top of the
# historical privapp-only baseline, so they're opt-in.
WITH_DEFAULT_PERMS=0

# Upstream source of the vendored-at-runtime tools.
UPSTREAM_REPO="${UPSTREAM_REPO:-micro5k/microg-unofficial-installer}"
UPSTREAM_REF="${UPSTREAM_REF:-main}"
UPSTREAM_GEN_PATH="tools/generate-perm-xml.sh"
UPSTREAM_DL_PATH="tools/dl-perm-list.sh"

log()  { printf '>> %s\n' "$*" >&2; }
warn() { printf '!  %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# --- args -----------------------------------------------------------------
APKS=()
while [ "$#" -gt 0 ]; do
	case "$1" in
		--dest)                 DEST_DIR="$2"; shift 2 ;;
		--def-dest)             DEF_DEST_DIR="$2"; shift 2 ;;
		--refresh)              REFRESH=1; shift ;;
		--default-permissions)  WITH_DEFAULT_PERMS=1; shift ;;
		-h|--help)              grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		-*)                     die "unknown option: $1" ;;
		*)                      APKS+=("$1"); shift ;;
	esac
done
[ "${#APKS[@]}" -gt 0 ] || die "no APK given. Usage: $0 [options] APK [APK...]"

command -v curl >/dev/null 2>&1 || die "missing dependency: curl"

# --- fetch the upstream tools (cached) ------------------------------------
# Download $2 (upstream repo-relative path) to $TOOLS_CACHE/$1. Falls back to a
# cached copy if the network is down; fails loudly with guidance if the upstream
# path 404s (which usually means the file was moved/renamed upstream).
fetch_tool() {
	local name="$1" relpath="$2" dest url
	dest="$TOOLS_CACHE/$name"
	url="https://raw.githubusercontent.com/$UPSTREAM_REPO/$UPSTREAM_REF/$relpath"

	if [ "$REFRESH" -eq 0 ] && [ -f "$dest" ]; then
		printf '%s\n' "$dest"; return 0
	fi
	mkdir -p "$TOOLS_CACHE"
	if curl -fsSL -o "$dest.part" "$url"; then
		mv "$dest.part" "$dest"
		printf '%s\n' "$dest"; return 0
	fi
	rm -f "$dest.part"
	if [ -f "$dest" ]; then
		warn "could not refresh $name from upstream; using cached copy."
		printf '%s\n' "$dest"; return 0
	fi
	die "Could not fetch upstream tool: $url
       The upstream layout may have changed (path moved/renamed). Fix by either:
         - pinning a known-good ref:  UPSTREAM_REF=<tag-or-commit> $0 ...
         - updating UPSTREAM_*_PATH in this script to the new location, or
         - placing the script manually at: $dest
       Upstream: https://github.com/$UPSTREAM_REPO"
}

log "Upstream tools: $UPSTREAM_REPO@$UPSTREAM_REF"
GEN_TOOL="$(fetch_tool generate-perm-xml.sh "$UPSTREAM_GEN_PATH")"
DL_TOOL="$(fetch_tool dl-perm-list.sh "$UPSTREAM_DL_PATH")"

# --- locate Android build tools -------------------------------------------
find_build_tool() {
	# $1 = tool name (aapt2 / aapt)
	local p roots root
	if p="$(command -v "$1" 2>/dev/null)"; then printf '%s\n' "$p"; return 0; fi
	roots=("${ANDROID_SDK_ROOT:-}" "${ANDROID_HOME:-}" \
		"$HOME/Android/Sdk" "$HOME/.local/share/android/sdk" \
		"$HOME/Library/Android/sdk" "/usr/lib/android-sdk")
	for root in "${roots[@]}"; do
		[ -n "$root" ] && [ -d "$root/build-tools" ] || continue
		p="$(find "$root/build-tools" -maxdepth 2 -name "$1" 2>/dev/null | sort -V | tail -n1)"
		[ -n "$p" ] && { printf '%s\n' "$p"; return 0; }
	done
	return 1
}

AAPT_PATH="${AAPT_PATH:-$(find_build_tool aapt2 || find_build_tool aapt || true)}"
[ -n "$AAPT_PATH" ] || die "aapt2/aapt not found. Install Android SDK build-tools or set AAPT_PATH."
export AAPT_PATH

# The upstream generator needs apksigner or keytool to compute the digest it
# embeds (which we strip afterwards). keytool is almost always on PATH; to also
# let it find apksigner, point ANDROID_SDK_ROOT at the SDK we found aapt in when
# the caller hasn't already set one.
if [ -z "${ANDROID_SDK_ROOT:-}" ] && [ -z "${ANDROID_HOME:-}" ]; then
	case "$AAPT_PATH" in
		*/build-tools/*) export ANDROID_SDK_ROOT="${AAPT_PATH%/build-tools/*}" ;;
	esac
fi

log "aapt:     $AAPT_PATH"

# The upstream generator embeds a sha256-cert-digest on each entry. We strip it:
# the allow-list then matches by package name only, which is the form that has a
# long track record on ROMs with ro.control_privapp_permissions=enforce (a digest
# the platform won't accept makes it reject the whole list and bootloop). $1 = XML.
strip_cert_digest() { sed -i -E 's/ sha256-cert-digest="[^"]*"//' "$1"; }

# --- ensure the AOSP permission database ----------------------------------
export TOOLS_DATA_DIR="$PERMDB_DIR"
if [ "$REFRESH" -eq 1 ] || [ ! -d "$PERMDB_DIR/perms" ]; then
	log "Building AOSP permission database (this hits android.googlesource.com)..."
	mkdir -p "$PERMDB_DIR"
	sh "$DL_TOOL" || die "dl-perm-list.sh failed."
else
	log "Using cached permission database: $PERMDB_DIR/perms"
fi

# --- generate, strip the cert digest, install under canonical names -------
mkdir -p "$DEST_DIR"
# Clear previously-generated files first so stale output can't linger and ship
# -- e.g. default-permissions from an earlier run that no longer enables them.
rm -f "$DEST_DIR"/privapp-permissions-*.xml
[ -d "$DEF_DEST_DIR" ] && rm -f "$DEF_DEST_DIR"/default-permissions-*.xml
[ "$WITH_DEFAULT_PERMS" -eq 1 ] && mkdir -p "$DEF_DEST_DIR"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/microg-perm.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Read the package= (or exception package=) attribute from a generated file.
pkg_of() { grep -o 'package="[^"]*"' "$1" | head -n1 | cut -d'"' -f2; }

for apk in "${APKS[@]}"; do
	[ -f "$apk" ] || die "APK not found: $apk"
	apk_abs="$(realpath "$apk")"
	rm -rf "$WORK/output"; mkdir -p "$WORK/output"

	log "Processing $(basename "$apk_abs") ..."
	# generate-perm-xml.sh writes to <cwd>/output/, so run it from $WORK.
	( cd "$WORK" && sh "$GEN_TOOL" "$apk_abs" )

	# privapp-permissions (required for privileged apps).
	priv="$(find "$WORK/output" -name 'privapp-permissions-*.xml' | head -n1)"
	if [ -n "$priv" ]; then
		pkg="$(pkg_of "$priv")"
		strip_cert_digest "$priv"
		cp -f "$priv" "$DEST_DIR/privapp-permissions-$pkg.xml"
		log "  privapp:  $DEST_DIR/privapp-permissions-$pkg.xml"
	else
		warn "  no privileged permissions produced for $(basename "$apk_abs")."
	fi

	# default-permissions (dangerous-perm auto-grants); opt-in only.
	if [ "$WITH_DEFAULT_PERMS" -eq 1 ]; then
		def="$(find "$WORK/output" -name 'default-permissions-*.xml' | head -n1)"
		if [ -n "$def" ]; then
			pkg="$(pkg_of "$def")"
			strip_cert_digest "$def"
			cp -f "$def" "$DEF_DEST_DIR/default-permissions-$pkg.xml"
			log "  default:  $DEF_DEST_DIR/default-permissions-$pkg.xml"
		fi
	fi
done

# Don't ship an empty default-permissions/ dir as dead weight.
[ -d "$DEF_DEST_DIR" ] && rmdir "$DEF_DEST_DIR" 2>/dev/null || true

log "Done."

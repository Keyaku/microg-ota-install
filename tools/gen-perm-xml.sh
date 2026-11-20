#!/usr/bin/env bash
#
# gen-perm-xml.sh
#
# Regenerates the flashable package's privapp-permissions XML from the actual
# APK(s) being shipped, so the grants never drift out of sync with what
# GmsCore/GmsCompanion request or with how a given Android release classifies
# each permission. Writes privapp-permissions-<pkg>.xml -> etc/permissions/.
#
# The allow-list embeds the signing-cert sha256 digest by default
# (sha256-cert-digest="..."), so the privileged grants bind to microG's signing
# key, not merely the package name -- the more-hardened form upstream ships. Pass
# --no-cert-digest to emit the digest-less (package-name-only) allow-list instead.
# default-permissions (dangerous-perm auto-grants -> etc/default-permissions/) are
# only emitted with --default-permissions.
#
# This wrapper (part of this repo, MIT-licensed) is a thin orchestrator around
# two THIRD-PARTY tools authored by ale5000, DOWNLOADED at run time from the
# upstream microg-unofficial-installer project rather than vendored, so upstream
# fixes are picked up automatically:
#   - dl-perm-list.sh      builds the AOSP permission database
#   - generate-perm-xml.sh reads an APK + the DB and emits the XML
# Those two are Apache-2.0 OR GPL-3.0-or-later WITH
# LicenseRef-Archive-packaging-exception. See tools/THIRD_PARTY.md.
#
# Usage:
#   tools/gen-perm-xml.sh [options] APK [APK...]
#     --dest DIR              privapp-permissions output dir
#                             (default: package/product/etc/permissions/)
#     --def-dest DIR          default-permissions output dir
#                             (default: package/product/etc/default-permissions/)
#     --default-permissions   also emit default-permissions (off by default)
#     --no-cert-digest        emit the digest-less (package-name-only) allow-list
#                             (default: embed the signing-cert sha256 digest)
#     --refresh               rebuild the permission DB into the cache (ignoring
#                             the committed tools/perm-db/)
#
# Env overrides:
#   UPSTREAM_REPO   default: micro5k/microg-unofficial-installer
#   UPSTREAM_REF    default: main   (pin to a tag/commit for reproducible builds)
#   AAPT_PATH / APKSIGNER_PATH / KEYTOOL_PATH / ANDROID_HOME   (all auto-detected)
#   MAX_ATTEMPTS / RETRY_DELAY / REQUEST_DELAY   dl-perm-list.sh download tuning
#
# Requires: curl + aapt2/aapt (Android SDK build-tools). apksigner or keytool is
# also needed to embed the digest (not with --no-cert-digest). wget is needed
# only to (re)build the permission DB, i.e. with --refresh or when no committed
# or cached DB is available.
# Caches live under $MICROG_OTA_CACHE (default ${XDG_CACHE_HOME:-~/.cache}/microg-ota-install/).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Cache root: explicit override (shared with build-microg-ota.sh) wins; else
# XDG_CACHE_HOME; else ~/.cache only if it already exists (never create it); else
# a repo-local .cache/.
if [ -n "${MICROG_OTA_CACHE:-}" ]; then
	CACHE_BASE="$MICROG_OTA_CACHE"
elif [ -n "${XDG_CACHE_HOME:-}" ]; then
	CACHE_BASE="$XDG_CACHE_HOME/microg-ota-install"
elif [ -d "$HOME/.cache" ]; then
	CACHE_BASE="$HOME/.cache/microg-ota-install"
else
	CACHE_BASE="$REPO_ROOT/.cache/microg-ota-install"
fi
TOOLS_CACHE="$CACHE_BASE/upstream-tools"
PERMDB_DIR="$CACHE_BASE/perm-db"

DEST_DIR="$REPO_ROOT/package/product/etc/permissions"
DEF_DEST_DIR="$REPO_ROOT/package/product/etc/default-permissions"
REFRESH=0
# default-permissions (dangerous-perm auto-grants) are an addition on top of the
# historical privapp-only baseline, so they're opt-in.
WITH_DEFAULT_PERMS=0
# Embed the signing-cert sha256 digest in the allow-list. ON by default: binds the
# privileged grants to microG's signing key (the hardened form upstream ships).
# --no-cert-digest falls back to the digest-less (package-name-only) allow-list.
WITH_CERT_DIGEST=1

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
		--cert-digest)          WITH_CERT_DIGEST=1; shift ;;
		--no-cert-digest)       WITH_CERT_DIGEST=0; shift ;;
		-h|--help)              grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		-*)                     die "unknown option: $1" ;;
		*)                      APKS+=("$1"); shift ;;
	esac
done
[ "${#APKS[@]}" -gt 0 ] || die "no APK given. Usage: $0 [options] APK [APK...]"

command -v curl >/dev/null 2>&1 || die "missing dependency: curl"

# --- fetch the upstream tools (cached) ------------------------------------
# Download $2 (upstream repo-relative path) to $TOOLS_CACHE/$1 on every run, so
# upstream fixes are always picked up. Falls back to a cached copy if the network
# is down; fails loudly with guidance if the upstream path 404s and nothing is
# cached (which usually means the file was moved/renamed upstream).
fetch_tool() {
	local name="$1" relpath="$2" dest url
	dest="$TOOLS_CACHE/$name"
	url="https://raw.githubusercontent.com/$UPSTREAM_REPO/$UPSTREAM_REF/$relpath"

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

# --- Android build tools ---------------------------------------------------
# The upstream generator auto-detects aapt2/aapt and (unless --no-cert-digest)
# apksigner/keytool on PATH or in the Android SDK (ANDROID_HOME / ANDROID_SDK_ROOT,
# then the usual per-OS locations). AAPT_PATH / APKSIGNER_PATH / KEYTOOL_PATH are
# honoured as overrides, simply by being inherited from the environment.

# --- ensure the AOSP permission database ----------------------------------
# Prefer the DB committed at tools/perm-db/ (vendored reference data): it makes
# builds offline and deterministic and, crucially, avoids android.googlesource.com,
# which rate-limits/blocks CI runner IPs. Only when it's absent (or on --refresh,
# to regenerate it) do we download into the cache via dl-perm-list.sh, which
# retries failed requests itself (MAX_ATTEMPTS / RETRY_DELAY / REQUEST_DELAY) and
# writes perms/.completed only once every API level was fetched.
# To update the committed DB: run with --refresh, then copy
#   "$PERMDB_DIR/perms/" -> tools/perm-db/perms/ .
REPO_DB="$REPO_ROOT/tools/perm-db"
if [ "$REFRESH" -eq 0 ] && [ -f "$REPO_DB/perms/.completed" ]; then
	log "Using committed AOSP permission database: $REPO_DB/perms"
	export TOOLS_DATA_DIR="$REPO_DB"
else
	export TOOLS_DATA_DIR="$PERMDB_DIR"
	if [ "$REFRESH" -eq 1 ] || [ ! -f "$PERMDB_DIR/perms/.completed" ]; then
		command -v wget >/dev/null 2>&1 || die "missing dependency: wget (needed by dl-perm-list.sh to build the permission DB)"
		log "Building AOSP permission database (this hits android.googlesource.com)..."
		mkdir -p "$PERMDB_DIR"
		sh "$DL_TOOL" --no-pause || die "dl-perm-list.sh failed (android.googlesource.com unreachable?)."
	else
		log "Using cached permission database: $PERMDB_DIR/perms"
	fi
fi

# --- generate, install under canonical names ------------------------------
mkdir -p "$DEST_DIR"
# Clear previously-generated files first so stale output can't linger and ship
# -- e.g. default-permissions from an earlier run that no longer enables them.
rm -f "$DEST_DIR"/privapp-permissions-*.xml
[ -d "$DEF_DEST_DIR" ] && rm -f "$DEF_DEST_DIR"/default-permissions-*.xml
[ "$WITH_DEFAULT_PERMS" -eq 1 ] && mkdir -p "$DEF_DEST_DIR"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/microg-perm.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

APKS_ABS=()
for apk in "${APKS[@]}"; do
	[ -f "$apk" ] || die "APK not found: $apk"
	APKS_ABS+=("$(realpath "$apk")")
done

gen_args=(--no-pause)
[ "$WITH_CERT_DIGEST" -eq 1 ] || gen_args+=(--no-cert-digest)
OUTPUT_DIR="$WORK/output" sh "$GEN_TOOL" "${gen_args[@]}" -- "${APKS_ABS[@]}" \
	|| die "generate-perm-xml.sh failed."

# Read the package= (or exception package=) attribute from a generated file.
pkg_of() { grep -o 'package="[^"]*"' "$1" | head -n1 | cut -d'"' -f2; }

# The generator names its output after the APK file; rename to the package name.
found=0
for priv in "$WORK"/output/privapp-permissions-*.xml; do
	[ -f "$priv" ] || continue
	pkg="$(pkg_of "$priv")"
	cp -f "$priv" "$DEST_DIR/privapp-permissions-$pkg.xml"
	log "  privapp:  $DEST_DIR/privapp-permissions-$pkg.xml"
	found=1
done
[ "$found" -eq 1 ] || warn "no privileged permissions produced."

# default-permissions (dangerous-perm auto-grants); opt-in only.
if [ "$WITH_DEFAULT_PERMS" -eq 1 ]; then
	for def in "$WORK"/output/default-permissions-*.xml; do
		[ -f "$def" ] || continue
		pkg="$(pkg_of "$def")"
		cp -f "$def" "$DEF_DEST_DIR/default-permissions-$pkg.xml"
		log "  default:  $DEF_DEST_DIR/default-permissions-$pkg.xml"
	done
fi

# Don't ship an empty default-permissions/ dir as dead weight.
[ -d "$DEF_DEST_DIR" ] && rmdir "$DEF_DEST_DIR" 2>/dev/null || true

log "Done."

#!/usr/bin/env bash
#
# build-microg-ota.sh
#
# 1. Fetches the latest microG builds (GmsCore, FakeStore) from the official
#    microg/GmsCore GitHub releases.
# 2. Downloads them into ./microG/ (original asset names kept).
# 3. Stages them into the flashable package's product/ tree, writes a
#    version.env (sourced by update-binary) from the fetched versions.
# 4. Zips the package contents (META-INF/ etc. at the archive root) and moves
#    the result into ./releases/.
#
# Requires: curl, jq, zip, unzip.

set -euo pipefail

# --- paths ----------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # repo root
PKG_DIR="$SCRIPT_DIR/package"
MICROG_DIR="$SCRIPT_DIR/microG"
RELEASES_DIR="$SCRIPT_DIR/releases"

GH_REPO="microg/GmsCore"
GH_API="https://api.github.com/repos/$GH_REPO/releases/latest"

# --- deps -----------------------------------------------------------------
for bin in curl jq zip unzip; do
	command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: missing dependency: $bin" >&2; exit 1; }
done

mkdir -p "$MICROG_DIR" "$RELEASES_DIR"

# --- fetch release metadata ----------------------------------------------
echo ">> Querying latest release of $GH_REPO ..."
CURL_AUTH=()
[ -n "${GITHUB_TOKEN:-}" ] && CURL_AUTH=(-H "Authorization: Bearer $GITHUB_TOKEN")

meta="$(curl -fsSL "${CURL_AUTH[@]}" -H "Accept: application/vnd.github+json" "$GH_API")"

tag="$(printf '%s' "$meta" | jq -r '.tag_name')"
published="$(printf '%s' "$meta" | jq -r '.published_at')"
echo ">> Latest release: $tag ($published)"

# Pick the standard (non -hw, non -user) .apk asset for a package prefix.
# Assets are named like com.google.android.gms-<verc>.apk
# Variants -hw.apk / -user.apk and .asc signatures are ignored.
pick_asset() {
	# $1 = package prefix (e.g. com.google.android.gms)
	printf '%s' "$meta" | jq -r --arg p "$1" '
		[.assets[]
			| select(.name | test("^" + $p + "-[0-9]+\\.apk$"))]
		| sort_by(.name) | last
		| if . == null then "" else "\(.name)\t\(.browser_download_url)\t\(.created_at)" end'
}

declare -A PKG_PREFIX=(
	[gms]="com.google.android.gms"
	[store]="com.android.vending"
)

declare -A ASSET_NAME ASSET_URL ASSET_VERC ASSET_TS

for key in gms store; do
	prefix="${PKG_PREFIX[$key]}"
	line="$(pick_asset "$prefix")"
	[ -n "$line" ] || { echo "ERROR: no asset for $prefix" >&2; exit 1; }
	IFS=$'\t' read -r name url ts <<<"$line"
	# version code = run of digits immediately after the prefix
	verc="$(printf '%s' "$name" | sed -E "s/^$prefix-([0-9]+)\.apk$/\1/")"
	ASSET_NAME[$key]="$name"
	ASSET_URL[$key]="$url"
	ASSET_VERC[$key]="$verc"
	ASSET_TS[$key]="$ts"
	echo "   $prefix: $name ($ts)"
done

# --- download into system/microG/ ----------------------------------------
download() {
	# $1 = url, $2 = dest, $3 = release timestamp (ISO-8601)
	if [ ! -f "$2" ]; then
		echo "   downloading $(basename "$2") ..."
		curl -fsSL "${CURL_AUTH[@]}" -o "$2.part" "$1"
		mv "$2.part" "$2"
	else
		echo "   already have $(basename "$2"), skipping download"
	fi
	# Set the file's mtime to the release/upload timestamp.
	touch -d "$3" "$2" 2>/dev/null || echo "   WARN: could not set timestamp on $(basename "$2")" >&2
}

echo ">> Downloading APKs into $MICROG_DIR ..."
for key in gms store; do
	download "${ASSET_URL[$key]}" "$MICROG_DIR/${ASSET_NAME[$key]}" "${ASSET_TS[$key]}"
done

# --- stage into package product/ tree -------------------------------------
echo ">> Staging into $PKG_DIR ..."
install_apk() {
	# $1 = source apk, $2 = dest path (within package)
	# -p preserves the source mtime so the release timestamp lands in the zip.
	mkdir -p "$(dirname "$2")"
	cp -fp "$1" "$2"
}

install_apk "$MICROG_DIR/${ASSET_NAME[gms]}"   "$PKG_DIR/product/priv-app/GmsCore/GmsCore.apk"
install_apk "$MICROG_DIR/${ASSET_NAME[store]}" "$PKG_DIR/product/priv-app/GmsCompanion/GmsCompanion.apk"

# GsfProxy is no longer published by microG (GmsCore now provides GSF). Reuse a
# legacy GsfProxy.apk if one is sitting in system/microG/, otherwise drop it
# from the package so the installer does not try to flash a missing payload.
if [ -f "$MICROG_DIR/GsfProxy.apk" ]; then
	install_apk "$MICROG_DIR/GsfProxy.apk" "$PKG_DIR/product/app/GsfProxy/GsfProxy.apk"
	echo "   GsfProxy: legacy $MICROG_DIR/GsfProxy.apk"
else
	rm -rf "$PKG_DIR/product/app/GsfProxy"
	echo "   GsfProxy: none available, omitting"
fi

# --- write version.env (sourced by update-binary) -------------------------
# Package (tooling) version -- owned by THIS repo, not microG. Derived from the
# git tag so a `vX.Y.Z` tag drives the release version; untagged/dirty trees get
# a descriptive dev string. Leading `v` is stripped for the zip name and banner.
pkgver="$(git -C "$SCRIPT_DIR" describe --tags --dirty 2>/dev/null || true)"
[ -n "$pkgver" ] || pkgver="0.0.0-dev.$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
pkgver="${pkgver#v}"

# microG payload version -- shown in the banner alongside pkgver so the person
# flashing sees both the wrapper and which microG GmsCore they are getting.
mgver="${tag#v}"
mgverc="${ASSET_VERC[gms]}"
mgdate="$(date -u -d "$published" +'%d %B %Y' 2>/dev/null || printf '%s' "$published")"

cat > "$PKG_DIR/version.env" <<EOF
# Generated by build-microg-ota.sh -- do not edit by hand.
pkgver="$pkgver"
mgver="$mgver"
mgverc="$mgverc"
mgdate="$mgdate"
EOF
echo ">> version.env: pkgver=$pkgver mgver=$mgver mgverc=$mgverc date=$mgdate"

# The shared helper scripts now live directly in package/ (recovery-tools.sh is
# a thin aggregator that sources the rest); they ship in both zips.
PKG_SH="$(cd "$PKG_DIR" && printf '%s ' *.sh)"

# Both zips are built from the SAME package/ tree and the SAME unified
# update-binary; the only difference is action.env (which the script dispatches
# on) and whether the APK/permission payload is bundled.
write_action() { printf 'ACTION=%s\n' "$1" > "$PKG_DIR/action.env"; }

# --- zip the installer (full: payload + action=install) -------------------
out="microg-ota-product-${pkgver}.zip"
tmpzip="$(mktemp -u "${TMPDIR:-/tmp}/microg-ota.XXXXXX.zip")"

echo ">> Zipping installer package ..."
write_action install
# cd into the package so META-INF/, product/, system/ land at the archive root.
( cd "$PKG_DIR" && zip -r -X "$tmpzip" \
	META-INF product system $PKG_SH version.env action.env \
	-x '*.DS_Store' )

mv -f "$tmpzip" "$RELEASES_DIR/$out"
# Keep a stable unversioned alias too.
cp -f "$RELEASES_DIR/$out" "$RELEASES_DIR/microg-ota-product.zip"

echo ">> Done: $RELEASES_DIR/$out"
echo ">>       $RELEASES_DIR/microg-ota-product.zip (alias)"

# --- zip the uninstaller (lightweight: no payload, action=uninstall) ------
uout="microg-uninstall.zip"
tmpzip="$(mktemp -u "${TMPDIR:-/tmp}/microg-uninstall.XXXXXX.zip")"

echo ">> Zipping uninstaller package ..."
write_action uninstall
( cd "$PKG_DIR" && zip -r -X "$tmpzip" \
	META-INF $PKG_SH action.env \
	-x '*.DS_Store' )

mv -f "$tmpzip" "$RELEASES_DIR/$uout"
echo ">> Done: $RELEASES_DIR/$uout"

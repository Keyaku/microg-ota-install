# microG OTA package

Flashable (recovery / addon.d) package that installs a minimal microG stack into the `product` partition, plus tooling to build it from the latest official microG releases.

## About this project

There exist a few microG flash installers, some more rudmentary than others, with the most recommended one being [microg-unofficial-installer](https://github.com/micro5k/microg-unofficial-installer), created by one of the official maintainers of microG [@ale5000-git](https://github.com/ale5000-git). Their project is strongly more robust than this; in no way does this serve as a direct replace, rather an alternative that, instead of flashing to the `/system` partition, it writes to `/product` due to the possibility of `/system` not having enough storage for a minimal microG installation (for instance: the Google Pixel 9).
Using `/product` instead is the next approach to conform to Android's [Shared system image](https://source.android.com/docs/core/architecture/partitions/shared-system-image) mechanisms.

In short: Until `microg-unofficial-installer` offers the possibility to install microG to `/product`, this is the better approach with the bare minimnum codebase to achieve it.

## Automatic installation

The quickest way to flash microG is the [`flash-microg.sh`](flash-microg.sh) script. It detects your device, downloads the latest release zip into a cache directory, sideloads it, and reboots.

Make sure [`adb`](https://developer.android.com/tools/adb) is installed, connect your device with USB debugging enabled, then run:

```sh
curl -fsSL https://raw.githubusercontent.com/Keyaku/microg-ota-install/main/flash-microg.sh | bash
```

Or, from a clone:

```sh
./flash-microg.sh
```

What it does:

1. **Detects a device.** With exactly one attached, it proceeds immediately; with several, it prompts you to pick one; with none, it waits for you to plug one in.
2. **Downloads the latest release** (`microg-ota-product-<x.y.z>.zip`) into `${XDG_CACHE_HOME:-~/.cache}/microg-ota-install/`, reusing the cache on subsequent runs.
3. **Reboots to sideload and flashes automatically.** On success it reboots the device back to system.
4. **Falls back gracefully** when a device doesn't support rebooting straight into sideload: it reboots to recovery and asks you to select *"Apply update from ADB"* (a.k.a. *"ADB sideload"*). It then auto-detects sideload mode and continues on its own; if it can't, it waits for you to press ENTER.

Notes:

- Set `ANDROID_SERIAL` to target a specific device non-interactively, or `GITHUB_TOKEN` to avoid GitHub API rate limits.
- If `adb sideload` reports an error (occasionally spurious; the device closes the connection as the flash finishes), the script lets you retry, continue (reboot anyway), or abort.
- The waits for a device to reach sideload/recovery/connected state are tuned low by default (`WAIT_SIDELOAD`/`WAIT_RECOVERY`=30s, `WAIT_DEVICE`=90s). A slower device may time out before it's ready; bump the relevant one by defining it before `bash` — e.g. `curl -fsSL <url> | WAIT_SIDELOAD=90 WAIT_RECOVERY=90 bash` (or `WAIT_SIDELOAD=90 ./flash-microg.sh` from a clone). On timeout the script tells you which variable to raise.

## Manual installation

### Download

Grab the prebuilt zips from the [**Releases**](https://github.com/Keyaku/microg-ota-install/releases/latest) page:

- **Installer** — `microg-ota-product-<x.y.z>.zip` (version-stamped; pick it from the latest release's assets).
- **Uninstaller** — [`microg-uninstall.zip`](https://github.com/Keyaku/microg-ota-install/releases/latest/download/microg-uninstall.zip).

Prefer building it yourself? See [Building from source](#building-from-source).

### Installing

Flash the installer zip (`microg-ota-product-<x.y.z>.zip`) in a recovery (TWRP/LineageOS recovery). Instructions below with `adb`:

**In case your device supports direct `sideload` reboot:
1. Reboot to Sideload mode: `adb reboot sideload`.
2. Pass the zip file to flash: `adb sideload microg-ota-product-<x.y.z>.zip`.
3. Reboot system normally: `adb reboot`.

**In case your device DOESN'T support direct `sideload` reboot:
1. Reboot to Recovery mode: `adb reboot recovery`.
2. Manually select "Apply update from ADB" (or "ADB sideload") to activate Sideload mode.
3. Pass the zip file to flash: `adb sideload microg-ota-product-<x.y.z>.zip`.
4. Reboot system normally: `adb reboot`.

## What it does

The APKs being installed are **GmsCore**, **GmsCompanion** and **GsfProxy**.

The installer mounts `system` and `product`, removes any previous copies, installs the APKs into `/product/{app,priv-app}`, drops the `privapp` permission XMLs, and installs the `addon.d` survival script so the apps persist across OTA updates.

Also, contrary to `microg-unofficial-installer`, this **does not** touch the `userdata` partition; in case you had a user installation of microG prior to this, you'd best uninstall it before flashing this.

### Native libraries (Cronet)

PackageManager does not unpack an APK's bundled JNI libraries for pre-installed (system/privileged) apps the way it does for user-installed ones — it expects them already on disk under `<app>/lib/<arch>/`. GmsCore ships `libcronet.<ver>.so`, and apps that pull Cronet from Play Services (e.g. Google Maps) crash with a missing `libcronet.<ver>.so` if it is not extracted. The installer therefore unpacks GmsCore's native libs into `/product/priv-app/GmsCore/lib/<arch>/` for the device's ABI at flash time, and the `addon.d` script regenerates them (`post-restore`) after each OTA so the fix survives updates.

### Storage guard rails

Before writing anything, the installer measures free space on `/product` (crediting back the footprint of any copy it is about to overwrite) and sizes the microG core and GmsCore's native libs. It then picks one of four outcomes — and never half-writes:

- **Core doesn't fit** → abort with a short message, leaving `/product` (and any existing install) untouched.
- **Core + all native libs fit** → install everything (`LIBMODE=full`).
- **Core fits, but only `libcronet` fits on top** → install the core and unpack `libcronet` only, with a light note (no prompt).
- **Only the core fits** → install the core, skip the native libs, and print a stronger warning recommending the user *also* install the GmsCore APK as a normal user app (a user install gets its libs unpacked automatically and provides Cronet).

A ~3 MB margin is reserved for filesystem overhead. The `addon.d` restore path applies the same tiered logic so an OTA can't overfill `/product` either.

## Uninstalling

Download and flash `microg-uninstall.zip` just as described in the [Manual installation](#manual-installation).
It removes the microG apps, the two privapp permission XMLs and the addon.d survival script from both `product` and `system`.

## Building from source

For development or to roll your own build instead of using a release, clone or download this project, then:

```sh
./build-microg-ota.sh
```

Optional: set `GITHUB_TOKEN` to avoid GitHub API rate limits.

The script:

1. Queries the latest `microg/GmsCore` GitHub release.
2. Downloads GmsCore (`com.google.android.gms`) and FakeStore (`com.android.vending`) into `microG/`.
3. Stages them into `package/product/` and writes `version.env` — the tooling version (`pkgver`, from `git describe`) plus the bundled microG version (`mgver`/`mgverc`/`mgdate`), both shown in the installer banner.
4. Zips the `package/` tree twice — `META-INF/`, `product/`, `system/` land at the archive root — writing `releases/microg-ota-product-<x.y.z>.zip` (`action.env=install`) and a lightweight `releases/microg-uninstall.zip` (`action.env=uninstall`, no payload).

The package version (`x.y.z`) is owned by this repo, **not** microG: it comes from the latest `vX.Y.Z` git tag via `git describe` (untagged/dirty trees build as a `0.0.0-dev.<hash>` string). The bundled microG APK version is tracked and displayed separately.

### GsfProxy

microG no longer publishes `GsfProxy` (GmsCore provides GSF). If a legacy `microG/GsfProxy.apk` is present, it is reused; otherwise, `GsfProxy` is omitted and the installer skips it.

### Layout

- `package/` — the single package source, shared by both the install and uninstall zips. `META-INF/com/google/android/update-binary` is one unified script that installs **or** uninstalls depending on the `action.env` marker the build stamps in.
- `package/*.sh` — shell helpers sourced by the unified `update-binary` via `recovery-tools.sh` (a thin aggregator over `output.sh`, `detect.sh`, `partitions.sh`, `native-libs.sh`, `microg-defs.sh`). They live alongside the package tree and ship in both zips.
- `build-microg-ota.sh` — fetches the latest microG builds, stages them, and zips both flavours into `releases/`.
- `releases/` — built flashable zips (gitignored).
- `microG/` — download cache for fetched APKs (gitignored).

Both zips are built from the same `package/` tree and the same `update-binary`. The install zip bundles the `product/`/`system/` payload and `action.env=install`; the uninstall zip carries neither payload — just `META-INF/`, the helper `*.sh`, and `action.env=uninstall`.

## Credits & licensing

The tooling and packaging scripts in this repository are licensed under the [MIT License](LICENSE).

The APKs this package fetches and installs — **GmsCore** (`com.google.android.gms`) and **GmsCompanion** (`com.android.vending`) — are **not** part of this repository. They are built and published by the [microG project](https://github.com/microg/GmsCore), which is licensed under the [Apache License 2.0](https://github.com/microg/GmsCore/blob/master/LICENSE). All credit for microG itself goes to its authors and contributors; this project only repackages their official releases into a flashable form.

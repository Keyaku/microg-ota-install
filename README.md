# microG OTA package

Flashable (recovery / addon.d) package that installs a minimal microG stack into the `product` partition, plus tooling to build it from the latest official microG releases.

## Layout

- `package/` — the single package source, shared by both the install and uninstall zips. `META-INF/com/google/android/update-binary` is one unified script that installs **or** uninstalls depending on the `action.env` marker the build stamps in.
- `package/*.sh` — shell helpers sourced by the unified `update-binary` via `recovery-tools.sh` (a thin aggregator over `output.sh`, `detect.sh`, `partitions.sh`, `native-libs.sh`, `microg-defs.sh`). They live alongside the package tree and ship in both zips.
- `build-microg-ota.sh` — fetches the latest microG builds, stages them, and zips both flavours into `releases/`.
- `releases/` — built flashable zips (gitignored).
- `microG/` — download cache for fetched APKs (gitignored).

Both zips are built from the same `package/` tree and the same `update-binary`. The install zip bundles the `product/`/`system/` payload and `action.env=install`; the uninstall zip carries neither payload — just `META-INF/`, the helper `*.sh`, and `action.env=uninstall`.

## Building a release

```sh
./build-microg-ota.sh
```

Optional: set `GITHUB_TOKEN` to avoid GitHub API rate limits.

The script:

1. Queries the latest `microg/GmsCore` GitHub release.
2. Downloads GmsCore (`com.google.android.gms`) and FakeStore (`com.android.vending`) into `microG/`.
3. Stages them into `package/product/` and writes `version.env` (sourced by the installer for the version banner).
4. Zips the `package/` tree twice — `META-INF/`, `product/`, `system/` land at the archive root — writing `releases/microg-ota-product-<ver>.zip` (plus a stable `microg-ota-product.zip` alias, with `action.env=install`) and a lightweight `releases/microg-uninstall.zip` (`action.env=uninstall`, no payload).

### GsfProxy

microG no longer publishes GsfProxy (GmsCore provides GSF). If a legacy `microG/GsfProxy.apk` is present it is reused; otherwise GsfProxy is omitted and the installer skips it.

## Installing

Flash `microg-ota-product.zip` in a recovery (TWRP/LineageOS recovery). The installer mounts `system` and `product`, removes any previous copies, installs the APKs into `/product/{app,priv-app}`, drops the privapp permission XMLs, and installs the `addon.d` survival script so the apps persist across OTA updates.

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

Flash `microg-uninstall.zip`. It removes the microG apps, the two privapp permission XMLs and the addon.d survival script from both `product` and `system`.

# microG OTA package

Flashable (recovery / addon.d) package that installs a minimal microG stack into the `product` partition, plus tooling to build it from the latest official microG releases.

## Download

Grab the prebuilt zips from the [**Releases**](https://github.com/Keyaku/microg-ota-install/releases/latest) page:

- **Installer** — `microg-ota-product-<x.y.z>.zip` (version-stamped; pick it from the latest release's assets).
- **Uninstaller** — [`microg-uninstall.zip`](https://github.com/Keyaku/microg-ota-install/releases/latest/download/microg-uninstall.zip) (stable name, so this "latest" link always resolves).

Prefer building it yourself? See [Building from source](#building-from-source).

## Installing

Flash the installer zip (`microg-ota-product-<x.y.z>.zip`) in a recovery (TWRP/LineageOS recovery). The installer mounts `system` and `product`, removes any previous copies, installs the APKs into `/product/{app,priv-app}`, drops the privapp permission XMLs, and installs the `addon.d` survival script so the apps persist across OTA updates.

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

## Building from source

For development or to roll your own build instead of using a release:

```sh
./build-microg-ota.sh
```

Optional: set `GITHUB_TOKEN` to avoid GitHub API rate limits.

The script:

1. Queries the latest `microg/GmsCore` GitHub release.
2. Downloads GmsCore (`com.google.android.gms`) and FakeStore (`com.android.vending`) into `microG/`.
3. Stages them into `package/product/` and writes `version.env` — the tooling version (`pkgver`, from `git describe`) plus the bundled microG version (`mgver`/`mgverc`/`mgdate`), both shown in the installer banner.
4. Zips the `package/` tree twice — `META-INF/`, `product/`, `system/` land at the archive root — writing `releases/microg-ota-product-<x.y.z>.zip` (`action.env=install`) and a lightweight `releases/microg-uninstall.zip` (`action.env=uninstall`, no payload).

The package version (`x.y.z`) is owned by this repo, **not** microG: it comes from the latest `vX.Y.Z` git tag via `git describe` (untagged/dirty trees build as a `0.0.0-dev.<hash>` string). The bundled microG APK version is tracked and displayed separately. Pushing a `vX.Y.Z` tag builds and publishes a GitHub Release automatically (see `.github/workflows/release.yml`).

### GsfProxy

microG no longer publishes GsfProxy (GmsCore provides GSF). If a legacy `microG/GsfProxy.apk` is present it is reused; otherwise GsfProxy is omitted and the installer skips it.

### Layout

- `package/` — the single package source, shared by both the install and uninstall zips. `META-INF/com/google/android/update-binary` is one unified script that installs **or** uninstalls depending on the `action.env` marker the build stamps in.
- `package/*.sh` — shell helpers sourced by the unified `update-binary` via `recovery-tools.sh` (a thin aggregator over `output.sh`, `detect.sh`, `partitions.sh`, `native-libs.sh`, `microg-defs.sh`). They live alongside the package tree and ship in both zips.
- `build-microg-ota.sh` — fetches the latest microG builds, stages them, and zips both flavours into `releases/`.
- `releases/` — built flashable zips (gitignored).
- `microG/` — download cache for fetched APKs (gitignored).

Both zips are built from the same `package/` tree and the same `update-binary`. The install zip bundles the `product/`/`system/` payload and `action.env=install`; the uninstall zip carries neither payload — just `META-INF/`, the helper `*.sh`, and `action.env=uninstall`.

## Credits & licensing

The tooling and packaging scripts in this repository are licensed under the [MIT License](LICENSE).

The APKs this package fetches and installs — **GmsCore** (`com.google.android.gms`) and **FakeStore** (`com.android.vending`) — are **not** part of this repository. They are built and published by the [microG project](https://github.com/microg/GmsCore), which is licensed under the [Apache License 2.0](https://github.com/microg/GmsCore/blob/master/LICENSE). All credit for microG itself goes to its authors and contributors; this project only repackages their official releases into a flashable form.

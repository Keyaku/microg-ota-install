# AOSP permission database (vendored)

`perms/base-permissions-api-<N>.xml` are the `<permission>` declarations extracted from AOSP's `core/res/AndroidManifest.xml` for each supported API level (23→36), produced by ale5000's `dl-perm-list.sh` (downloaded by [`../gen-perm-xml.sh`](../gen-perm-xml.sh); see [`../THIRD_PARTY.md`](../THIRD_PARTY.md)). `gen-perm-xml.sh` cross-references an APK's requested permissions against these to decide which are privileged.

## Why it's committed

`gen-perm-xml.sh` fetches these per-API manifests from `android.googlesource.com`, which **rate-limits/blocks datacenter IPs** — so building in CI (GitHub Actions) fails intermittently or outright. Vendoring the DB makes every build **offline, deterministic, and CI-safe**. The data is stable: it only changes when a new Android API level is added (the source tags are pinned in `dl-perm-list.sh`).

## Updating

When a new Android API level appears (or to refresh):

```sh
tools/gen-perm-xml.sh --refresh <some.apk>                 # re-downloads into the cache
cp -r "${XDG_CACHE_HOME:-$HOME/.cache}/microg-ota-install/perm-db/perms/." tools/perm-db/perms/
```

Then commit the changed `perms/`. The content is AOSP-derived (Apache-2.0); the files are factual permission declarations.

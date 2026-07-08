# Third-party tools

`tools/gen-perm-xml.sh` (part of this repository, MIT-licensed) is only an orchestrator. The actual permission-generation logic is **not** authored by this project — it is downloaded at run time from ale5000's [`microg-unofficial-installer`](https://github.com/micro5k/microg-unofficial-installer) and cached locally:

| Downloaded tool | Upstream path | Purpose |
| --- | --- | --- |
| `generate-perm-xml.sh` | `tools/generate-perm-xml.sh` | Reads an APK's requested permissions (`aapt`/`aapt2`), cross-references them against the AOSP permission database, and emits `privapp-permissions` / `default-permissions` XML. |
| `dl-perm-list.sh` | `tools/dl-perm-list.sh` | Downloads AOSP `<permission>` declarations for each supported Android API level (23→36) into that database. |

## Why downloaded and not vendored

Fetching from upstream means upstream fixes (new Android API levels, permission reclassifications, parser fixes) are picked up automatically instead of silently rotting in a checked-in copy.

- **Source:** <https://github.com/micro5k/microg-unofficial-installer>
- **Ref:** the `UPSTREAM_REF` env var (default `main`). Pin it to a tag or commit for reproducible builds: `UPSTREAM_REF=<tag-or-commit> tools/gen-perm-xml.sh …`.
- **Cache:** `${XDG_CACHE_HOME:-~/.cache}/microg-ota-install/upstream-tools/` (refresh with `--refresh`). The cache doubles as an offline fallback if the network is down.
- **If a download 404s** (upstream moved/renamed a file), the orchestrator aborts with a message telling you to update `UPSTREAM_*_PATH` in `gen-perm-xml.sh`, pin a different ref, or drop the script into the cache manually.

## Author & licensing

- **Author / copyright:** © 2025 ale5000 ([@ale5000-git](https://github.com/ale5000-git)), an official microG maintainer.
- **License:** `GPL-3.0-or-later OR Apache-2.0` (dual-licensed, recipient's choice) — as declared in each script's SPDX header — **not** this repository's MIT license. When redistributing these tools (e.g. if you cache and re-ship them), honor their terms.
- The XML files they *generate* are declared `CC0-1.0` by the tools themselves, so the permission XMLs produced for the flashable package carry no license encumbrance.

All credit for the permission-generation approach and code goes to ale5000 and the microG project.

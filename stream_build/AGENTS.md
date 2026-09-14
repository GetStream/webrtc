# WebRTC Makefile wrapper

Public API:

```
cd stream_build
make bootstrap            # once; CONFIRM=1 in CI
make build|test|package ios|android|macos|windows [VAR=value ...]
make combine
make rename apple|android
```

`build` is gn+ninja. `package` only copies/lipo/zips artifacts already in `OUT`, then writes `LICENSE.md` unless `SKIP_LICENSES=1`.
Do not reintroduce Fastlane or wrap `tools_webrtc/ios/build_ios_libs.py`.

Apple package writes per-platform trees so they do not overwrite:

```
$(PRODUCTS)/ios/WebRTC.xcframework
$(PRODUCTS)/macos/WebRTC.xcframework
$(PRODUCTS)/WebRTC.xcframework              # make combine
$(PRODUCTS)/renamed/StreamWebRTC.xcframework
$(PRODUCTS)/renamed/libwebrtc.aar
```

`make combine` globs `$(PRODUCTS)/*/WebRTC.xcframework` (ios, macos, and any
future sibling such as visionos/tvos). One match is copied to the stable
output path; two or more are merged with `xcodebuild -create-xcframework`.

`make rename` copies the original artifact and rebrands the copy. The
GetStream/webrtc release keeps `WebRTC.xcframework` / `libwebrtc.aar`.
Renamed copies feed stream-video-swift-webrtc and stream-video-android-webrtc.

## Layout

- `Makefile` — verb + platform dispatch
- `gn/common.args` — Stream policy GN args
- `gn/slices.tsv` — slice → ninja target + GN overlay
- `scripts/bootstrap.sh` — wrap this checkout as Chromium `webrtc/src`
- `webrtc.mk` — catch-all parent `webrtc/Makefile` template (copied if missing)
- `scripts/deps.sh` — `gclient sync` at `DEPS_ROOT`; uses this `src` (no second clone)
- `scripts/gn-gen.sh` — args.gn + gn gen
- `scripts/package-apple.sh` — lipo + create-xcframework
- `scripts/combine-apple.sh` — discover platform xcframeworks and merge
- `scripts/rename-apple.sh` — copy WebRTC.xcframework → StreamWebRTC
- `scripts/rename-android.sh` — copy libwebrtc.aar into PRODUCTS/renamed/
- `scripts/package-android.sh` — zip libwebrtc.aar
- `scripts/package-windows.sh` — copy Windows libs
- `scripts/run-ios-tests.sh`
- `scripts/check.sh`

Required tree (gclient parent **must** be named `webrtc`, checkout **must**
be named `src`):

```
webrtc/                      # DEPS_ROOT / gclient root
  Makefile                   # bootstrap copies webrtc.mk if missing
  .gclient
  .gclient-git-cache/        # GIT_CACHE_PATH
  src/                       # this git checkout (WEBRTC_SRC)
    DEPS
    stream_build/
    third_party/             # gclient writes here
  out/                       # ninja (sibling of src)
```

`solutions.name = src`, `managed: False`. `src` is this worktree, not a
symlink and not a second clone. Official DEPS stays (`src/build`,
`src/third_party`, `gclient_gn_args_file = src/build/config/gclient_args.gni`).

`make bootstrap` (interactive; `CONFIRM=1` in CI) renames/wraps into that
layout. Other verbs
(except `help` / `check` / `bootstrap`) go through
`scripts/bootstrap.sh --check` and fail with `run: make bootstrap` unless
the tree is `webrtc/src` (real directory, not a symlink). `deps` /
`build` / `test` / `package` / `runhooks` also require parent `.gclient`
(`--check --gclient`). `make bootstrap` copies `webrtc.mk` to
`$(DEPS_ROOT)/Makefile` if that file is missing (parent is outside git).

CI checks out with `path: src` so `GITHUB_WORKSPACE` is the webrtc-named
folder. `DEPS_ROOT=$GITHUB_WORKSPACE`. `OUT` is `$DEPS_ROOT/out`
(sibling of `src`). There is no shared Linux Deps job. iOS, macOS,
and Android jobs run in parallel after Plan:

1. `actions/checkout` `src` at `webrtc_ref`
2. HIT Hetzner `build-ios` / `build-macos` / `build-android` (`if_missing:
   skip`; Build dispatch `skip_deps_cache` skips the download)
3. `make deps` (`RUN_HOOKS=1`, host GCS rust-toolchain on Apple)
4. `make build` / `make test` (`SKIP_DEPS=1`)
5. `artifact-put` `.gclient-git-cache` plus reusable `src/resources`
   and `.cipd` if non-empty (always after miss / `skip_deps_cache`;
   skip PUT when HIT size delta is < 1GiB)

Keys: `artifacts/<github.repository>/build-{ios,macos,android}.tar`.
Same-OS only (Linux tree on Mac is forbidden). Members: required
`.gclient-git-cache`; `src/resources` and `.cipd` if non-empty.
Not packed: working trees (`src/third_party`, `src/build`,
`src/buildtools`, `src/testing`, `src/tools`, `src/ios`), `out/`,
`.gclient` / `.gclient_entries` (setup-webrtc writes `.gclient` every
job), `src/.git`, Stream-tracked `src` files, `products/`. Restore:
checkout `src`, extract git-cache to `GIT_CACHE_PATH`
(`${{ github.workspace }}/.gclient-git-cache`), `src/resources`, and
`.cipd` if present. Do not strip git alternates; `make deps` runs
`rewrite_git_cache_alternates` so Linux-packed cache paths retarget
to this runner. Always `make deps` after HIT (cheap from cache).
Build `CONFIG` is dispatch (default release); `make test` always uses debug
in `out/ios_tests` / `out/webrtc_tests`, so those subdirs do not mix
with slice dirs. Test.yml HITs the same `build-ios` / `build-macos`
keys. Windows Deps still uploads `deps-windows` to GitHub.
Package/Release Build jobs also `make package` and upload `products-*`
(GitHub). Package combine consumes `products-*` (no third ninja) and
uploads `final-*`. Release attaches `final-*`. `TARGET_OS` is the
platform of that job (`ios`, `mac`, `android,unix`).

Hetzner: `artifact-download` Range-GETs with
`s3api get-object --range bytes=${have}-` into a partial file and
resumes from bytes already on disk (not `s3 cp` from 0).
While GET runs, logs `have / ContentLength (%)` every ~15s.
`artifact-put` tars to a file then multipart `aws s3 cp` to
`<bucket>/artifacts/<github.repository>/<stem>.tar` with
`--endpoint-url https://hel1.your-objectstorage.com` and region
`hel1`. A pipe GET/PUT is one HTTP body; a drop is IncompleteRead
of the whole object. Peak disk is tar + tree (~2x); delete the tar
after extract/upload. `aws s3 cp` / `s3api` talk to Hetzner's
S3-compatible API, not AWS.
Callers pass org secrets via `with:`
`${{ secrets.HETZNER_ACCESS_KEY_CI_ARTIFACTS }}`,
`${{ secrets.HETZNER_SECRET_ACCESS_KEY_CI_ARTIFACTS }}`, and
`${{ secrets.HETZNER_BUCKET_CI_ARTIFACTS }}`. Composite actions must
not use `${{ secrets.* }}`. `products-*` / `final-*` stay on
`actions/upload-artifact`.

## Host gates

- bootstrap: any host (writes layout + `.gclient`; no depot_tools)
- ios / macos / combine / rename apple: Darwin
- android / rename android: Linux for build/package; rename android is a file copy on any host
- windows: Windows
- deps / runhooks: any host with depot_tools

## Overrides

| Name | Role |
|------|------|
| `CONFIG` | `release` (default, `is_debug=false`) or `debug`. `make test` always uses debug. |
| `GN_ARGS` | extra `key=value` tokens, applied last |
| `DEPS_ROOT` | gclient parent (`webrtc/`; `.gclient` + `src/` + `out/`) |
| `WEBRTC_SRC` | this git checkout (`webrtc/src`; default: parent of `stream_build/`) |
| `OUT` / `PRODUCTS` | ninja dirs / packaged output (default under `DEPS_ROOT`, sibling of `src`) |
| `GIT_CACHE_PATH` | gclient object cache (default `DEPS_ROOT/.gclient-git-cache`) |
| `ARCHS` | android ABI or windows cpu (`arm64-v8a`, `x64`, …) |
| `JOBS` | ninja/gclient parallelism |
| `SHALLOW` | `1` (default) `gclient sync --no-history --shallow`. `0` = full history. |
| `ZIP` | `1` to zip Apple/Windows products |
| `XCFRAMEWORK` | input for `make rename apple` (default `$(PRODUCTS)/WebRTC.xcframework`) |
| `AAR` | input for `make rename android` (default `$(PRODUCTS)/libwebrtc.aar`) |
| `RENAMED` | output dir for `make rename` (default `$(PRODUCTS)/renamed`) |
| `SKIP_DEPS` | `1` skips gclient sync only; build still runs. Default `0`. |
| `SKIP_LICENSES` | `1` skips `LICENSE.md` generation only; lipo/zip still run. Default `0`. |
| `SKIP_MACCATALYST` | `1` drops `catalyst-arm64` and `catalyst-x64` from ios build+package only. Default `0`. |

```bash
make bootstrap CONFIRM=1
make build ios
make build ios SKIP_DEPS=1
make build ios SKIP_MACCATALYST=1
make build android ARCHS=arm64-v8a SKIP_DEPS=1
make package ios SKIP_DEPS=1 SKIP_LICENSES=1
make package macos SKIP_DEPS=1 SKIP_LICENSES=1
make combine SKIP_LICENSES=1
make rename apple
make rename android
```

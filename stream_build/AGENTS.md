# WebRTC Makefile wrapper

Public API:

```
cd stream_build
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
- `scripts/deps.sh` — gclient parent at `DEPS_ROOT` with `src` → git root
- `scripts/gn-gen.sh` — args.gn + gn gen
- `scripts/package-apple.sh` — lipo + create-xcframework
- `scripts/combine-apple.sh` — discover platform xcframeworks and merge
- `scripts/rename-apple.sh` — copy WebRTC.xcframework → StreamWebRTC
- `scripts/rename-android.sh` — copy libwebrtc.aar into PRODUCTS/renamed/
- `scripts/package-android.sh` — zip libwebrtc.aar
- `scripts/package-windows.sh` — copy Windows libs
- `scripts/run-ios-tests.sh`
- `scripts/check.sh`

Default `DEPS_ROOT` is `<git>/.gclient_deps` (gitignored). `src` there is a
symlink, not a nested clone; `make deps` does not reset that git checkout.
Ninja output is `DEPS_ROOT/out`.

## Host gates

- ios / macos / combine / rename apple: Darwin
- android / rename android: Linux for build/package; rename android is a file copy on any host
- windows: Windows
- deps / runhooks: any host with depot_tools

## Overrides

| Name | Role |
|------|------|
| `CONFIG` | `release` (default, `is_debug=false`) or `debug`. `make test` always uses debug. |
| `GN_ARGS` | extra `key=value` tokens, applied last |
| `DEPS_ROOT` | gclient parent (`.gclient` + `src` symlink + `out/`) |
| `WEBRTC_SRC` | git root containing `DEPS` (default: parent of `stream_build/`) |
| `OUT` / `PRODUCTS` | ninja dirs / packaged output (default under `DEPS_ROOT`) |
| `ARCHS` | android ABI or windows cpu (`arm64-v8a`, `x64`, …) |
| `JOBS` | ninja/gclient parallelism |
| `ZIP` | `1` to zip Apple/Windows products |
| `XCFRAMEWORK` | input for `make rename apple` (default `$(PRODUCTS)/WebRTC.xcframework`) |
| `AAR` | input for `make rename android` (default `$(PRODUCTS)/libwebrtc.aar`) |
| `RENAMED` | output dir for `make rename` (default `$(PRODUCTS)/renamed`) |
| `SKIP_DEPS` | `1` skips gclient sync only; build still runs. Default `0`. |
| `SKIP_LICENSES` | `1` skips `LICENSE.md` generation only; lipo/zip still run. Default `0`. |
| `SKIP_MACCATALYST` | `1` drops `catalyst-arm64` and `catalyst-x64` from ios build+package only. Default `0`. |

```bash
make build ios
make build ios SKIP_DEPS=1
make build ios DEPS_ROOT=/tmp/webrtc-deps
make build ios SKIP_MACCATALYST=1
make build android ARCHS=arm64-v8a SKIP_DEPS=1
make package ios SKIP_DEPS=1 SKIP_LICENSES=1
make package macos SKIP_DEPS=1 SKIP_LICENSES=1
make combine SKIP_LICENSES=1
make rename apple
make rename android
```

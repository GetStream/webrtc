# Vendored libwebrtc C++ wrapper

This directory is a **vendored copy** of the `libwebrtc` C++ wrapper (the `libwebrtc::` API
in `include/`, implemented in `src/`), which produces the `libwebrtc.so` / `libwebrtc.dll`
consumed by the `stream_webrtc_flutter` desktop platforms (linux / windows / webOS).

It used to be fetched at build time from the upstream repo; it is now committed here so the
fork owns it directly and compatibility fixes live in-tree as ordinary source. Apple and
Android do not use this wrapper — they build from the native WebRTC SDK.

## Origin

- Upstream: https://github.com/webrtc-sdk/libwebrtc
- Vendored from commit: `8586c07c4c0a82f645cb0867913d43593a9e9466`
- License: MIT (see `LICENSE`) — © 湖北捷智云技术有限公司 (Hubei Jiezhiyun Technology Co., Ltd.)

## Local modifications vs. upstream (m145 compatibility)

The upstream wrapper targets `webrtc-sdk/webrtc@m144`. The following changes make it compile
against `GetStream/webrtc@m145`:

- `include/rtc_types.h` — add `#include <cstdint>` (m145's libc++ no longer provides fixed-width
  int types transitively).
- `src/rtc_frame_cryptor_impl.h` — drop the `KeyProviderOptions::key_derivation_algorithm`
  assignment; m145 has no such field / `webrtc::KeyDerivationAlgorithm` enum, so core's default
  key derivation is used.
- `src/rtc_peerconnection_factory_impl.cc` — `CreateAudioDeviceModule` is 2-arg in m145
  (`const Environment&, AudioLayer`); dropped the removed 3rd argument.

## Updating

Syncing from upstream is now a **deliberate manual merge**: re-copy the desired upstream commit
over this tree, re-apply the local modifications above, and re-verify the desktop build. Update
this file's pinned-commit reference when you do.

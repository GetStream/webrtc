### WebRTC

This repository is a fork of the WebRTC project. The original README can be found [here](README_webrtc.md).

## Package Renaming Script

This repository includes a comprehensive package renaming script (`rename_webrtc_package.sh`) that transforms the WebRTC package structure from `org.webrtc` to `io.getstream.webrtc` for CI/CD builds for Android 

### What it does

The script performs a complete package transformation including:

- **Directory Structure**: Moves files from `org/webrtc/` to `io/getstream/webrtc/`
- **Package References**: Updates all package declarations from `org.webrtc` to `io.getstream.webrtc`
- **JNI Functions**: Renames JNI function prefixes from `Java_org_webrtc_` to `Java_io_getstream_webrtc_`
- **Library Names**: Updates library references from `libjingle_peerconnection_so` to `libstream_jingle_peerconnection_so`
- **File References**: Updates all file path references across multiple file types

### Usage

```bash
# Make the script executable and run it
chmod +x rename_webrtc_package.sh
./rename_webrtc_package.sh

# Skip backup creation (for CI/CD environments)
./rename_webrtc_package.sh --no-backup

# Show help
./rename_webrtc_package.sh --help
```

### Transformations Applied

| Original | New |
|----------|-----|
| `org/webrtc` | `io/getstream/webrtc` |
| `org.webrtc` | `io.getstream.webrtc` |
| `Java_org_webrtc_` | `Java_io_getstream_webrtc_` |
| `libjingle_peerconnection_so` | `libstream_jingle_peerconnection_so` |
| `jingle_peerconnection_so` | `stream_jingle_peerconnection_so` |
| `org_webrtc` | `io_getstream_webrtc` |

### License
- [WebRTC](https://webrtc.org) software is licensed under the [BSD license](https://github.com/GetStream/webrtc/blob/main/LICENSE).
- Includes patches from [shiguredo-webrtc-build](https://github.com/shiguredo-webrtc-build), licensed under the [Apache 2.0](https://github.com/shiguredo-webrtc-build/webrtc-build/blob/master/LICENSE).
- Includes modifications from [webrtc-sdk/webrtc](https://github.com/webrtc-sdk/webrtc), licensed under the [BSD license](https://github.com/webrtc-sdk/webrtc/blob/master/LICENSE).

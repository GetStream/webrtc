### WebRTC

This repository is a fork of the WebRTC project. The original README can be found [here](README_webrtc.md).

### Fork Specifics

#### `.gitignore`

Due to the fork specifics, the repo's `.gitignore` has been updated to match the fork's requirements.

#### Building Tools

The fork contains a `fastlane` pipeline to produce builds for iOS. To access the pipeline you need to switch into `src/fastlane` and execute `bundle exec fastlane lanes` to see the available lanes.

##### Building for iOS

- Build the WebRTC library for iOS `bundle exec fastlane ios build`

## Package Renaming Script (Android only)

This repository includes a comprehensive package renaming script (`rename_webrtc_package.sh`) that transforms the WebRTC package structure from `org.webrtc` to `io.getstream.webrtc` for CI/CD builds for Android 

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

### License
- [WebRTC](https://webrtc.org) software is licensed under the [BSD license](https://github.com/GetStream/webrtc/blob/main/LICENSE).
- Includes patches from [shiguredo-webrtc-build](https://github.com/shiguredo-webrtc-build), licensed under the [Apache 2.0](https://github.com/shiguredo-webrtc-build/webrtc-build/blob/master/LICENSE).
- Includes modifications from [webrtc-sdk/webrtc](https://github.com/webrtc-sdk/webrtc), licensed under the [BSD license](https://github.com/webrtc-sdk/webrtc/blob/master/LICENSE).

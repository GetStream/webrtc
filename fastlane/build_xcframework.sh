#!/usr/bin/env bash

gclient root
gclient config --spec 'solutions = [
{
    "name": "src",
    "url": "git@github.com:GetStream/webrtc.git",
    "deps_file": "DEPS",
    "managed": False,
    "custom_deps": {},
},
]
target_os = ["ios", "mac"]
'
gclient sync -j8 -v

cd src
./tools_webrtc/ios/build_ios_libs.py \
  --deployment-target 13.0 \
  --extra-gn-args \
    is_debug=false \
    use_goma=false \
    use_rtti=false \
    rtc_libvpx_build_vp9=true
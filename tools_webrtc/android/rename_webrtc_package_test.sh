#!/bin/bash

# Fixture test for rename_webrtc_package.sh. Builds a tiny WebRTC-shaped tree,
# rewrites it, and checks the Android package moves without touching synced
# dependency directories or Apple sources.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
rename_script="$script_dir/rename_webrtc_package.sh"
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

mkdir -p \
  "$work_dir/sdk/android/api/org/webrtc" \
  "$work_dir/sdk/android/src/jni" \
  "$work_dir/third_party/org/webrtc" \
  "$work_dir/sdk/objc"

cat > "$work_dir/BUILD.gn" <<'EOF'
# fixture root
EOF

cat > "$work_dir/sdk/android/api/org/webrtc/PeerConnectionFactory.java" <<'EOF'
package org.webrtc;

public class PeerConnectionFactory {
  private String nativeLibraryName = "jingle_peerconnection_so";
}
EOF

cat > "$work_dir/sdk/android/BUILD.gn" <<'EOF'
rtc_shared_library("libjingle_peerconnection_so") {
}
deps = [ ":libjingle_peerconnection_so" ]
EOF

cat > "$work_dir/sdk/android/src/jni/jni_helpers.h" <<'EOF'
#define JOW(rettype, name) Java_org_webrtc_##name
extern "C" void Java_org_webrtc_Foo(void);
void* org_webrtc_StatsReport_clazz(void);
EOF

cat > "$work_dir/third_party/org/webrtc/Leave.java" <<'EOF'
package org.webrtc;
EOF

cat > "$work_dir/sdk/objc/RTCDispatcher.m" <<'EOF'
dispatch_queue_create("org.webrtc.RTCDispatcherAudioSession", DISPATCH_QUEUE_SERIAL);
EOF

mkdir -p "$work_dir/tools_webrtc/android/templates"
cat > "$work_dir/tools_webrtc/android/templates/pom.jinja" <<'EOF'
<groupId>org.webrtc</groupId>
EOF

(
  cd "$work_dir"
  bash "$rename_script" --no-backup
)

java_file="$work_dir/sdk/android/api/io/getstream/webrtc/PeerConnectionFactory.java"
if [ ! -f "$java_file" ]; then
  echo "Expected rewritten Java file at $java_file"
  exit 1
fi
if [ -e "$work_dir/sdk/android/api/org/webrtc/PeerConnectionFactory.java" ]; then
  echo "Original Java file was not moved"
  exit 1
fi

grep -q 'package io.getstream.webrtc;' "$java_file"
grep -q 'nativeLibraryName = "stream_jingle_peerconnection_so"' "$java_file"
grep -q 'rtc_shared_library("libstream_jingle_peerconnection_so")' "$work_dir/sdk/android/BUILD.gn"
grep -q ':libstream_jingle_peerconnection_so' "$work_dir/sdk/android/BUILD.gn"
if grep -q 'libstream_stream_jingle_peerconnection_so' "$work_dir/sdk/android/BUILD.gn"; then
  echo "Library name was rewritten twice"
  exit 1
fi
grep -q 'Java_io_getstream_webrtc_##name' "$work_dir/sdk/android/src/jni/jni_helpers.h"
grep -q 'Java_io_getstream_webrtc_Foo' "$work_dir/sdk/android/src/jni/jni_helpers.h"
grep -q 'io_getstream_webrtc_StatsReport_clazz' "$work_dir/sdk/android/src/jni/jni_helpers.h"

if ! grep -q 'package org.webrtc;' "$work_dir/third_party/org/webrtc/Leave.java"; then
  echo "third_party was rewritten"
  exit 1
fi
if ! grep -q 'org.webrtc.RTCDispatcherAudioSession' "$work_dir/sdk/objc/RTCDispatcher.m"; then
  echo "Apple source was rewritten"
  exit 1
fi
if ! grep -q '<groupId>org.webrtc</groupId>' "$work_dir/tools_webrtc/android/templates/pom.jinja"; then
  echo "pom template was rewritten"
  exit 1
fi

echo "rename_webrtc_package_test passed"

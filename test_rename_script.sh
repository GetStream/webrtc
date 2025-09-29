#!/bin/bash

# Test script for rename_webrtc_package.sh
# This script creates a test environment to safely test the renaming functionality

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_status() {
    echo -e "${BLUE}[TEST]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Test configuration
TEST_DIR="webrtc_test_$(date +%Y%m%d_%H%M%S)"
ORIGINAL_DIR=$(pwd)

print_status "Creating test environment in $TEST_DIR..."

# Create test directory
mkdir -p "$TEST_DIR"
cd "$TEST_DIR"

# Copy only the necessary parts for testing
print_status "Copying test files..."
mkdir -p sdk/android/api/org/webrtc
mkdir -p sdk/android/src/java/org/webrtc
mkdir -p sdk/android/tests/src/org/webrtc
mkdir -p test/android/org/webrtc/native_test

# Copy some sample Java files
cp "$ORIGINAL_DIR/sdk/android/api/org/webrtc/SimulcastVideoEncoderFactory.java" sdk/android/api/org/webrtc/ 2>/dev/null || true
cp "$ORIGINAL_DIR/sdk/android/src/java/org/webrtc/WebRtcClassLoader.java" sdk/android/src/java/org/webrtc/ 2>/dev/null || true

# Create some test files with org.webrtc references
print_status "Creating test files with org.webrtc references..."

# Create a test Java file
cat > sdk/android/api/org/webrtc/TestClass.java << 'EOF'
package org.webrtc;

import org.webrtc.VideoEncoder;
import org.webrtc.VideoDecoder;

public class TestClass {
    public static void main(String[] args) {
        System.out.println("Testing org.webrtc package");
    }
}
EOF

# Create a test C++ file with JNI references
cat > sdk/android/src/jni/test_jni.cc << 'EOF'
#include <jni.h>

extern "C" JNIEXPORT jlong JNICALL Java_org_webrtc_TestClass_nativeCreate(JNIEnv* env, jclass clazz) {
    return 0;
}

extern "C" JNIEXPORT void JNICALL Java_org_webrtc_TestClass_nativeDestroy(JNIEnv* env, jclass clazz, jlong nativePtr) {
    // Implementation
}
EOF

# Create a test BUILD.gn file
cat > sdk/android/BUILD.gn << 'EOF'
rtc_android_library("test_lib") {
  sources = [
    "api/org/webrtc/TestClass.java",
    "src/java/org/webrtc/WebRtcClassLoader.java",
  ]
  deps = [":base_java"]
}
EOF

# Create a test Python file
cat > tools/test_script.py << 'EOF'
#!/usr/bin/env python3

import os
import sys

# Test org.webrtc references
PACKAGE_NAME = "org.webrtc"
JNI_PREFIX = "Java_org_webrtc_"
LIB_NAME = "libjingle_peerconnection_so"

def test_function():
    print(f"Testing {PACKAGE_NAME} package")
    print(f"JNI prefix: {JNI_PREFIX}")
    print(f"Library: {LIB_NAME}")
EOF

# Create a test XML file
cat > sdk/android/AndroidManifest.xml << 'EOF'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application>
        <activity android:name="org.webrtc.TestActivity" />
    </application>
</manifest>
EOF

# Create a test markdown file
cat > docs/test.md << 'EOF'
# WebRTC Test Documentation

This document tests org.webrtc references.

## JNI Functions
- Java_org_webrtc_TestClass_nativeCreate
- Java_org_webrtc_TestClass_nativeDestroy

## Library References
- libjingle_peerconnection_so

## Package References
- org.webrtc.VideoEncoder
- org.webrtc.VideoDecoder
EOF

print_success "Test environment created with sample files"

# Copy the rename script
cp "$ORIGINAL_DIR/rename_webrtc_package.sh" ./
chmod +x rename_webrtc_package.sh

print_status "Running the rename script in test mode..."

# Run the script with --no-backup for testing
./rename_webrtc_package.sh --no-backup

print_status "Testing completed! Checking results..."

# Verify the results
echo ""
print_status "=== VERIFICATION RESULTS ==="

# Check if new directory structure exists
if [ -d "sdk/android/api/io/getstream/webrtc" ]; then
    print_success "✓ New directory structure created"
else
    print_error "✗ New directory structure not found"
fi

# Check if old directory structure is removed
if [ ! -d "sdk/android/api/org/webrtc" ]; then
    print_success "✓ Old directory structure removed"
else
    print_warning "⚠ Old directory structure still exists"
fi

# Check if Java files were moved
if [ -f "sdk/android/api/io/getstream/webrtc/TestClass.java" ]; then
    print_success "✓ Java files moved to new location"
else
    print_error "✗ Java files not moved"
fi

# Check package declarations
if grep -q "package io.getstream.webrtc" sdk/android/api/io/getstream/webrtc/TestClass.java 2>/dev/null; then
    print_success "✓ Package declarations updated"
else
    print_error "✗ Package declarations not updated"
fi

# Check import statements
if grep -q "import io.getstream.webrtc" sdk/android/api/io/getstream/webrtc/TestClass.java 2>/dev/null; then
    print_success "✓ Import statements updated"
else
    print_error "✗ Import statements not updated"
fi

# Check JNI function names
if grep -q "Java_io_getstream_webrtc_" sdk/android/src/jni/test_jni.cc 2>/dev/null; then
    print_success "✓ JNI function names updated"
else
    print_error "✗ JNI function names not updated"
fi

# Check library names
if grep -q "libstream_jingle_peerconnection_so" tools/test_script.py 2>/dev/null; then
    print_success "✓ Library names updated"
else
    print_error "✗ Library names not updated"
fi

# Check BUILD.gn files
if grep -q "io/getstream/webrtc" sdk/android/BUILD.gn 2>/dev/null; then
    print_success "✓ BUILD.gn files updated"
else
    print_error "✗ BUILD.gn files not updated"
fi

# Check for remaining old references
remaining_org_webrtc=$(grep -r "org\.webrtc" . --include="*.java" --include="*.cc" --include="*.gn" --include="*.py" --include="*.xml" --include="*.md" 2>/dev/null | wc -l || echo "0")
if [ "$remaining_org_webrtc" -eq 0 ]; then
    print_success "✓ No remaining org.webrtc references found"
else
    print_warning "⚠ Found $remaining_org_webrtc remaining org.webrtc references"
fi

# Show some sample results
echo ""
print_status "=== SAMPLE RESULTS ==="
echo "New Java file content:"
head -5 sdk/android/api/io/getstream/webrtc/TestClass.java 2>/dev/null || echo "File not found"

echo ""
echo "Updated C++ file content:"
head -5 sdk/android/src/jni/test_jni.cc 2>/dev/null || echo "File not found"

echo ""
echo "Updated BUILD.gn content:"
head -5 sdk/android/BUILD.gn 2>/dev/null || echo "File not found"

# Cleanup
print_status "Cleaning up test environment..."
cd "$ORIGINAL_DIR"
rm -rf "$TEST_DIR"

print_success "Test completed and cleaned up!"
echo ""
print_status "If all checks passed, the script is working correctly!"
print_status "You can now run it on your actual WebRTC codebase."
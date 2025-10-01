#!/bin/bash

# WebRTC Package Renaming Script (fixed)
# Fixes an issue where "Java_org_webrtc_" could be converted to
# "Java_io.getstream.webrtc_" because the dot in "org.webrtc" was
# treated as a regex '.' and matched the underscore in "org_webrtc".
#
# This version:
#  - Escapes the dot in the old package when used as a sed pattern
#    so "org.webrtc" does NOT match "org_webrtc".
#  - Performs the JNI-prefix replacement first as an extra safety.
#  - Uses safer find loops (null-delimited) to handle spaces in filenames.
#
# Usage: chmod +x rename_webrtc_package_fixed.sh && ./rename_webrtc_package_fixed.sh

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
OLD_PACKAGE="org.webrtc"
NEW_PACKAGE="io.getstream.webrtc"
OLD_PACKAGE_PATH="org/webrtc"
NEW_PACKAGE_PATH="io/getstream/webrtc"
OLD_JNI_PREFIX="Java_org_webrtc_"
NEW_JNI_PREFIX="Java_io_getstream_webrtc_"
OLD_JNI_UNDERSCORE="org_webrtc"
NEW_JNI_UNDERSCORE="io_getstream_webrtc"
BARE_OLD_LIB_NAME="jingle_peerconnection_so"
BARE_NEW_LIB_NAME="stream_jingle_peerconnection_so"
OLD_LIB_NAME="libjingle_peerconnection_so"
NEW_LIB_NAME="libstream_jingle_peerconnection_so"

# File extensions to process
FILE_EXTENSIONS=(
    "*.java"
    "*.cc"
    "*.h"
    "*.cpp"
    "*.hpp"
    "*.c"
    "*.gn"
    "*.gni"
    "*.xml"
    "*.py"
    "*.sh"
    "*.md"
    "*.txt"
    "*.json"
    "*.properties"
)

print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if file should be skipped
should_skip_file() {
    local file="$1"
    # Skip script files and backup files
    if [[ "$file" == *"rename_webrtc_package"* ]] ||
       [[ "$file" == *"test_rename_script"* ]] ||
       [[ "$file" == *.bak ]] ||
       [[ "$file" == *"webrtc_backup"* ]]; then
        return 0  # Skip this file
    fi
    return 1  # Don't skip this file
}

# Function to create backup
create_backup() {
    local backup_dir="webrtc_backup_$(date +%Y%m%d_%H%M%S)"
    print_status "Creating backup in $backup_dir..."
    cp -r . "../$backup_dir"
    print_success "Backup created at ../$backup_dir"
}

# Function to find all org/webrtc directories
find_org_webrtc_dirs() {
    find . -type d -path "*/org/webrtc" | sort
}

# Function to create new directory structure
create_new_dirs() {
    print_status "Creating new directory structure..."

    for old_dir in $(find_org_webrtc_dirs); do
        new_dir=$(echo "$old_dir" | sed "s|org/webrtc|$NEW_PACKAGE_PATH|g")
        print_status "Creating directory: $new_dir"
        mkdir -p "$new_dir"
    done

    print_success "Directory structure created"
}

# Function to move Java files
move_java_files() {
    print_status "Moving Java files from org/webrtc to $NEW_PACKAGE_PATH..."

    local moved_count=0
    for old_dir in $(find_org_webrtc_dirs); do
        if [ -d "$old_dir" ]; then
            new_dir=$(echo "$old_dir" | sed "s|org/webrtc|$NEW_PACKAGE_PATH|g")

            # Move all files in the directory
            if [ "$(ls -A "$old_dir" 2>/dev/null)" ]; then
                print_status "Moving files from $old_dir to $new_dir"
                mv "$old_dir"/* "$new_dir/" 2>/dev/null || true
                moved_count=$((moved_count + $(ls -1 "$new_dir" 2>/dev/null | wc -l)))
            fi
        fi
    done

    print_success "Moved $moved_count files"
}

# Function to remove empty org/webrtc directories
cleanup_empty_dirs() {
    print_status "Cleaning up empty org/webrtc directories..."

    # Remove empty directories in reverse order (deepest first)
    for old_dir in $(find_org_webrtc_dirs | sort -r); do
        if [ -d "$old_dir" ] && [ -z "$(ls -A "$old_dir" 2>/dev/null)" ]; then
            print_status "Removing empty directory: $old_dir"
            rmdir "$old_dir" 2>/dev/null || true
        fi
    done

    print_success "Empty directories cleaned up"
}

# Function to replace all references in files (fixed)
replace_all_references() {
    print_status "Replacing all references in files..."

    local count=0
    local OLD_PACKAGE_ESC=${OLD_PACKAGE//./\\.}
    local NEW_PACKAGE_REPL=${NEW_PACKAGE//&/\\&}
    local NEW_PACKAGE_PATH_REPL=${NEW_PACKAGE_PATH//&/\\&}

    for ext in "${FILE_EXTENSIONS[@]}"; do
        while IFS= read -r -d '' file; do
            if should_skip_file "$file"; then
                continue
            fi

            local needs_update=false
            if grep -q "$OLD_PACKAGE_PATH" "$file" 2>/dev/null ||
               grep -q "$OLD_PACKAGE" "$file" 2>/dev/null ||
               grep -q "$OLD_JNI_PREFIX" "$file" 2>/dev/null ||
               grep -q "$OLD_LIB_NAME" "$file" 2>/dev/null ||
               grep -q "$OLD_JNI_UNDERSCORE" "$file" 2>/dev/null ||
               grep -q "$BARE_OLD_LIB_NAME" "$file" 2>/dev/null; then
                needs_update=true
            fi

            if [ "$needs_update" = true ]; then
                print_status "Updating: $file"

                # 1. Path references: org/webrtc → io/getstream/webrtc
                sed -i.bak "s|$OLD_PACKAGE_PATH|$NEW_PACKAGE_PATH_REPL|g" "$file"

                # 2. Package refs: org.webrtc → io.getstream.webrtc
                sed -i.bak "s|$OLD_PACKAGE_ESC|$NEW_PACKAGE_REPL|g" "$file"

                # 3. JNI prefixes: Java_org_webrtc_ → Java_io_getstream_webrtc_
                sed -i.bak "s|$OLD_JNI_PREFIX|$NEW_JNI_PREFIX|g" "$file"

                # 4. Bare library names (must come before lib… replacement)
                sed -i.bak "s|$BARE_OLD_LIB_NAME|$BARE_NEW_LIB_NAME|g" "$file"

                # 5. Full library names
                sed -i.bak "s|$OLD_LIB_NAME|$NEW_LIB_NAME|g" "$file"

                # 6. JNI-style symbols: org_webrtc → io_getstream_webrtc
                sed -i.bak "s|$OLD_JNI_UNDERSCORE|$NEW_JNI_UNDERSCORE|g" "$file"

                rm -f "$file.bak"
                count=$((count + 1))
            fi
        done < <(find . -name "$ext" -type f -print0 2>/dev/null)
    done

    print_success "Updated $count files"
}

# Function to validate changes
validate_changes() {
    print_status "Validating changes..."
    local errors=0

    # Check for old package refs
    local remaining_pkg=$(grep -r "org\.webrtc" . --include="*" 2>/dev/null | grep -v "rename_webrtc_package" | wc -l)
    if [ "$remaining_pkg" -gt 0 ]; then
        print_warning "Found $remaining_pkg remaining org.webrtc references"
        errors=$((errors + 1))
    fi

    # Check for old path refs
    local remaining_path=$(grep -r "org/webrtc" . --include="*" 2>/dev/null | grep -v "rename_webrtc_package" | wc -l)
    if [ "$remaining_path" -gt 0 ]; then
        print_warning "Found $remaining_path remaining org/webrtc path references"
        errors=$((errors + 1))
    fi

    # Check for JNI prefixes
    local remaining_jni=$(grep -r "Java_org_webrtc_" . --include="*" 2>/dev/null | grep -v "rename_webrtc_package" | wc -l)
    if [ "$remaining_jni" -gt 0 ]; then
        print_warning "Found $remaining_jni remaining Java_org_webrtc_ references"
        errors=$((errors + 1))
    fi

    # ✅ NEW: check for JNI-style underscore symbols
    local remaining_jni_symbols=$(grep -r "org_webrtc" . --include="*" 2>/dev/null | grep -v "rename_webrtc_package" | wc -l)
    if [ "$remaining_jni_symbols" -gt 0 ]; then
        print_warning "Found $remaining_jni_symbols remaining org_webrtc JNI-style references"
        errors=$((errors + 1))
    fi

    # Check for lib name
    local remaining_lib=$(grep -r "$OLD_LIB_NAME" . --include="*" 2>/dev/null | grep -v "rename_webrtc_package" | wc -l)
    if [ "$remaining_lib" -gt 0 ]; then
        print_warning "Found $remaining_lib remaining $OLD_LIB_NAME references"
        errors=$((errors + 1))
    fi

    if [ $errors -eq 0 ]; then
        print_success "All validations passed!"
    else
        print_error "Validation found $errors issues"
        return 1
    fi
}

# Function to show summary
show_summary() {
    print_status "=== RENAMING SUMMARY ==="
    echo "Old package: $OLD_PACKAGE"
    echo "New package: $NEW_PACKAGE"
    echo "Old path: $OLD_PACKAGE_PATH"
    echo "New path: $NEW_PACKAGE_PATH"
    echo "Old JNI prefix: $OLD_JNI_PREFIX"
    echo "New JNI prefix: $NEW_JNI_PREFIX"
    echo "Old library: $OLD_LIB_NAME"
    echo "New library: $NEW_LIB_NAME"
    echo ""

    # Count files in new structure
    local new_java_files=$(find . -path "*/$NEW_PACKAGE_PATH/*.java" -type f 2>/dev/null | wc -l || echo "0")
    print_success "Java files in new structure: $new_java_files"

    # Count remaining old structure
    local old_java_files=$(find . -path "*/org/webrtc/*.java" -type f 2>/dev/null | wc -l || echo "0")
    if [ "$old_java_files" -gt 0 ]; then
        print_warning "Remaining Java files in old structure: $old_java_files"
    fi
}

# Main execution
main() {
    print_status "Starting WebRTC package renaming from $OLD_PACKAGE to $NEW_PACKAGE"
    echo ""

    # Check if we're in the right directory
    if [ ! -f "BUILD.gn" ] || [ ! -d "sdk" ]; then
        print_error "This script must be run from the WebRTC root directory"
        exit 1
    fi

    # Create backup
    if [ "$1" != "--no-backup" ]; then
        create_backup
        echo ""
    else
        print_warning "Skipping backup (--no-backup flag provided)"
    fi

    # Execute transformations
    create_new_dirs
    move_java_files
    cleanup_empty_dirs
    replace_all_references

    echo ""

    # Validate changes
    if validate_changes; then
        show_summary
        print_success "Package renaming completed successfully!"
    else
        print_error "Package renaming completed with warnings. Please review the output above."
        exit 1
    fi
}

# Handle command line arguments
case "${1:-}" in
    --help|-h)
        echo "WebRTC Package Renaming Script"
        echo ""
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  --no-backup    Skip creating backup before renaming"
        echo "  --help, -h     Show this help message"
        echo ""
        echo "This script renames the WebRTC package from org.webrtc to io.getstream.webrtc"
        echo "and handles all related transformations for CI/CD builds."
        echo ""
        echo "Simple search and replace rules:"
        echo "  - org/webrtc -> io/getstream/webrtc (path references)"
        echo "  - org.webrtc -> io.getstream.webrtc (package references)"
        echo "  - Java_org_webrtc_ -> Java_io_getstream_webrtc_ (JNI functions)"
        echo "  - libjingle_peerconnection_so -> libstream_jingle_peerconnection_so (library names)"
        exit 0
        ;;
    *)
        main "$@"
        ;;
esac

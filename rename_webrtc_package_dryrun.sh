#!/bin/bash

# WebRTC Package Renaming Script - DRY RUN VERSION
# This script shows what changes would be made without actually making them

set -e

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
    echo -e "${BLUE}[DRY RUN]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[WOULD DO]${NC} $1"
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

# Function to find all org/webrtc directories
find_org_webrtc_dirs() {
    find . -type d -path "*/org/webrtc" | sort
}

# Function to show what directories would be created
show_directory_changes() {
    print_status "=== DIRECTORY CHANGES ==="
    
    local dir_count=0
    for old_dir in $(find_org_webrtc_dirs); do
        new_dir=$(echo "$old_dir" | sed "s|org/webrtc|$NEW_PACKAGE_PATH|g")
        print_success "Would create: $new_dir"
        dir_count=$((dir_count + 1))
    done
    
    print_status "Total directories that would be created: $dir_count"
    echo ""
}

# Function to show what files would be moved
show_file_moves() {
    print_status "=== FILE MOVES ==="
    
    local file_count=0
    for old_dir in $(find_org_webrtc_dirs); do
        if [ -d "$old_dir" ]; then
            for file in "$old_dir"/*; do
                if [ -f "$file" ]; then
                    filename=$(basename "$file")
                    new_dir=$(echo "$old_dir" | sed "s|org/webrtc|$NEW_PACKAGE_PATH|g")
                    print_success "Would move: $file -> $new_dir/$filename"
                    file_count=$((file_count + 1))
                fi
            done
        fi
    done
    
    print_status "Total files that would be moved: $file_count"
    echo ""
}

# Function to show package declaration changes
show_package_changes() {
    print_status "=== PACKAGE DECLARATION CHANGES ==="
    
    local count=0
    for ext in "${FILE_EXTENSIONS[@]}"; do
        for file in $(find . -name "$ext" -type f 2>/dev/null); do
            if should_skip_file "$file"; then
                continue
            fi
            if grep -q "package $OLD_PACKAGE" "$file" 2>/dev/null; then
                print_success "Would update package declaration in: $file"
                echo "  Current: $(grep "package $OLD_PACKAGE" "$file" | head -1)"
                echo "  Would change to: package $NEW_PACKAGE"
                count=$((count + 1))
            fi
        done
    done
    
    print_status "Total files with package declarations to update: $count"
    echo ""
}

# Function to show import changes
show_import_changes() {
    print_status "=== IMPORT STATEMENT CHANGES ==="
    
    local count=0
    for ext in "${FILE_EXTENSIONS[@]}"; do
        for file in $(find . -name "$ext" -type f 2>/dev/null); do
            if should_skip_file "$file"; then
                continue
            fi
            if grep -q "import $OLD_PACKAGE" "$file" 2>/dev/null; then
                print_success "Would update imports in: $file"
                grep "import $OLD_PACKAGE" "$file" | head -3 | while read line; do
                    echo "  Current: $line"
                    echo "  Would change to: $(echo "$line" | sed "s|$OLD_PACKAGE|$NEW_PACKAGE|g")"
                done
                count=$((count + 1))
            fi
        done
    done
    
    print_status "Total files with imports to update: $count"
    echo ""
}

# Function to show package reference changes
show_package_reference_changes() {
    print_status "=== PACKAGE REFERENCE CHANGES ==="
    
    local count=0
    for ext in "${FILE_EXTENSIONS[@]}"; do
        for file in $(find . -name "$ext" -type f 2>/dev/null); do
            if should_skip_file "$file"; then
                continue
            fi
            if grep -q "$OLD_PACKAGE" "$file" 2>/dev/null; then
                print_success "Would update references in: $file"
                grep -n "$OLD_PACKAGE" "$file" | head -3 | while read line; do
                    echo "  Line $line"
                done
                count=$((count + 1))
            fi
        done
    done
    
    print_status "Total files with package references to update: $count"
    echo ""
}

# Function to show path reference changes
show_path_reference_changes() {
    print_status "=== PATH REFERENCE CHANGES ==="
    
    local count=0
    for ext in "${FILE_EXTENSIONS[@]}"; do
        for file in $(find . -name "$ext" -type f 2>/dev/null); do
            if should_skip_file "$file"; then
                continue
            fi
            if grep -q "$OLD_PACKAGE_PATH" "$file" 2>/dev/null; then
                print_success "Would update path references in: $file"
                grep -n "$OLD_PACKAGE_PATH" "$file" | head -3 | while read line; do
                    echo "  Line $line"
                done
                count=$((count + 1))
            fi
        done
    done
    
    print_status "Total files with path references to update: $count"
    echo ""
}

# Function to show JNI function changes
show_jni_changes() {
    print_status "=== JNI FUNCTION CHANGES ==="
    
    local count=0
    for ext in "${FILE_EXTENSIONS[@]}"; do
        for file in $(find . -name "$ext" -type f 2>/dev/null); do
            if should_skip_file "$file"; then
                continue
            fi
            if grep -q "$OLD_JNI_PREFIX" "$file" 2>/dev/null; then
                print_success "Would update JNI functions in: $file"
                grep -n "$OLD_JNI_PREFIX" "$file" | head -3 | while read line; do
                    echo "  Line $line"
                done
                count=$((count + 1))
            fi
        done
    done
    
    print_status "Total files with JNI functions to update: $count"
    echo ""
}

# Function to show library name changes
show_library_changes() {
    print_status "=== LIBRARY NAME CHANGES ==="
    
    local count=0
    for ext in "${FILE_EXTENSIONS[@]}"; do
        for file in $(find . -name "$ext" -type f 2>/dev/null); do
            if should_skip_file "$file"; then
                continue
            fi
            if grep -q "$OLD_LIB_NAME" "$file" 2>/dev/null; then
                print_success "Would update library names in: $file"
                grep -n "$OLD_LIB_NAME" "$file" | head -3 | while read line; do
                    echo "  Line $line"
                done
                count=$((count + 1))
            fi
        done
    done
    
    print_status "Total files with library names to update: $count"
    echo ""
}

# Function to show summary statistics
show_summary() {
    print_status "=== SUMMARY STATISTICS ==="
    
    # Count directories
    local dir_count=$(find_org_webrtc_dirs | wc -l)
    print_status "Directories to create: $dir_count"
    
    # Count Java files
    local java_count=$(find . -path "*/org/webrtc/*.java" -type f 2>/dev/null | wc -l)
    print_status "Java files to move: $java_count"
    
    # Count package declarations
    local package_count=0
    for ext in "${FILE_EXTENSIONS[@]}"; do
        for file in $(find . -name "$ext" -type f 2>/dev/null); do
            if should_skip_file "$file"; then
                continue
            fi
            if grep -q "package $OLD_PACKAGE" "$file" 2>/dev/null; then
                package_count=$((package_count + 1))
            fi
        done
    done
    print_status "Files with package declarations: $package_count"
    
    # Count import statements
    local import_count=0
    for ext in "${FILE_EXTENSIONS[@]}"; do
        for file in $(find . -name "$ext" -type f 2>/dev/null); do
            if should_skip_file "$file"; then
                continue
            fi
            if grep -q "import $OLD_PACKAGE" "$file" 2>/dev/null; then
                import_count=$((import_count + 1))
            fi
        done
    done
    print_status "Files with import statements: $import_count"
    
    # Count total references
    local total_refs=$(grep -r "$OLD_PACKAGE" . --include="*.java" --include="*.cc" --include="*.h" --include="*.cpp" --include="*.hpp" --include="*.c" --include="*.gn" --include="*.gni" --include="*.xml" --include="*.py" --include="*.sh" --include="*.md" --include="*.txt" --include="*.json" --include="*.properties" 2>/dev/null | grep -v "rename_webrtc_package" | grep -v "test_rename_script" | wc -l || echo "0")
    print_status "Total org.webrtc references: $total_refs"
    
    # Count JNI references
    local jni_refs=$(grep -r "$OLD_JNI_PREFIX" . --include="*.java" --include="*.cc" --include="*.h" --include="*.cpp" --include="*.hpp" --include="*.c" --include="*.gn" --include="*.gni" --include="*.xml" --include="*.py" --include="*.sh" --include="*.md" --include="*.txt" --include="*.json" --include="*.properties" 2>/dev/null | grep -v "rename_webrtc_package" | grep -v "test_rename_script" | wc -l || echo "0")
    print_status "Total JNI function references: $jni_refs"
    
    # Count library references
    local lib_refs=$(grep -r "$OLD_LIB_NAME" . --include="*.java" --include="*.cc" --include="*.h" --include="*.cpp" --include="*.hpp" --include="*.c" --include="*.gn" --include="*.gni" --include="*.xml" --include="*.py" --include="*.sh" --include="*.md" --include="*.txt" --include="*.json" --include="*.properties" 2>/dev/null | grep -v "rename_webrtc_package" | grep -v "test_rename_script" | wc -l || echo "0")
    print_status "Total library name references: $lib_refs"
    
    echo ""
    print_warning "This is a DRY RUN - no actual changes will be made!"
    print_status "To apply these changes, run: ./rename_webrtc_package.sh"
}

# Main execution
main() {
    print_status "WebRTC Package Renaming - DRY RUN MODE"
    print_status "Showing what changes would be made from $OLD_PACKAGE to $NEW_PACKAGE"
    echo ""
    
    # Check if we're in the right directory
    if [ ! -f "BUILD.gn" ] || [ ! -d "sdk" ]; then
        print_error "This script must be run from the WebRTC root directory"
        exit 1
    fi
    
    show_directory_changes
    show_file_moves
    show_package_changes
    show_import_changes
    show_package_reference_changes
    show_path_reference_changes
    show_jni_changes
    show_library_changes
    show_summary
}

# Handle command line arguments
case "${1:-}" in
    --help|-h)
        echo "WebRTC Package Renaming Script - DRY RUN VERSION"
        echo ""
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  --help, -h     Show this help message"
        echo ""
        echo "This script shows what changes would be made without actually making them."
        echo "Use this to preview the changes before running the actual rename script."
        exit 0
        ;;
    *)
        main "$@"
        ;;
esac
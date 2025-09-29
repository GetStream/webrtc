#!/bin/bash

# WebRTC Package Renaming Script
# This script renames the WebRTC package from org.webrtc to io.getstream.webrtc
# and handles all related transformations for CI/CD builds.

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
OLD_LIB_NAME="libjingle_peerconnection_so"
NEW_LIB_NAME="libstream_jingle_peerconnection_so"

# Directories to process
BASE_DIRS=(
    "sdk/android/api"
    "sdk/android/src/java"
    "sdk/android/tests/src"
    "sdk/android/native_unittests"
    "sdk/android/instrumentationtests/src"
    "test/android"
)

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

# Function to print colored output
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

# Function to replace package declarations in Java files
replace_package_declarations() {
    print_status "Replacing package declarations in Java files..."
    
    local count=0
    for ext in "${FILE_EXTENSIONS[@]}"; do
        for file in $(find . -name "$ext" -type f 2>/dev/null); do
            if should_skip_file "$file"; then
                continue
            fi
            if grep -q "package $OLD_PACKAGE" "$file" 2>/dev/null; then
                print_status "Updating package declaration in: $file"
                sed -i.bak "s|package $OLD_PACKAGE|package $NEW_PACKAGE|g" "$file"
                rm -f "$file.bak"
                count=$((count + 1))
            fi
        done
    done
    
    print_success "Updated package declarations in $count files"
}

# Function to replace import statements
replace_imports() {
    print_status "Replacing import statements..."
    
    local count=0
    for ext in "${FILE_EXTENSIONS[@]}"; do
        for file in $(find . -name "$ext" -type f 2>/dev/null); do
            if should_skip_file "$file"; then
                continue
            fi
            if grep -q "import $OLD_PACKAGE" "$file" 2>/dev/null; then
                print_status "Updating imports in: $file"
                sed -i.bak "s|import $OLD_PACKAGE|import $NEW_PACKAGE|g" "$file"
                rm -f "$file.bak"
                count=$((count + 1))
            fi
        done
    done
    
    print_success "Updated imports in $count files"
}

# Function to replace all org.webrtc references
replace_package_references() {
    print_status "Replacing all org.webrtc references..."
    
    local count=0
    for ext in "${FILE_EXTENSIONS[@]}"; do
        for file in $(find . -name "$ext" -type f 2>/dev/null); do
            if should_skip_file "$file"; then
                continue
            fi
            if grep -q "$OLD_PACKAGE" "$file" 2>/dev/null; then
                print_status "Updating references in: $file"
                sed -i.bak "s|$OLD_PACKAGE|$NEW_PACKAGE|g" "$file"
                rm -f "$file.bak"
                count=$((count + 1))
            fi
        done
    done
    
    print_success "Updated references in $count files"
}

# Function to replace org/webrtc path references
replace_path_references() {
    print_status "Replacing org/webrtc path references..."
    
    local count=0
    for ext in "${FILE_EXTENSIONS[@]}"; do
        for file in $(find . -name "$ext" -type f 2>/dev/null); do
            if should_skip_file "$file"; then
                continue
            fi
            if grep -q "$OLD_PACKAGE_PATH" "$file" 2>/dev/null; then
                print_status "Updating path references in: $file"
                sed -i.bak "s|$OLD_PACKAGE_PATH|$NEW_PACKAGE_PATH|g" "$file"
                rm -f "$file.bak"
                count=$((count + 1))
            fi
        done
    done
    
    print_success "Updated path references in $count files"
}

# Function to replace JNI function names
replace_jni_functions() {
    print_status "Replacing JNI function names..."
    
    local count=0
    for ext in "${FILE_EXTENSIONS[@]}"; do
        for file in $(find . -name "$ext" -type f 2>/dev/null); do
            if should_skip_file "$file"; then
                continue
            fi
            if grep -q "$OLD_JNI_PREFIX" "$file" 2>/dev/null; then
                print_status "Updating JNI functions in: $file"
                sed -i.bak "s|$OLD_JNI_PREFIX|$NEW_JNI_PREFIX|g" "$file"
                rm -f "$file.bak"
                count=$((count + 1))
            fi
        done
    done
    
    print_success "Updated JNI functions in $count files"
}

# Function to replace library names
replace_library_names() {
    print_status "Replacing library names..."
    
    local count=0
    for ext in "${FILE_EXTENSIONS[@]}"; do
        for file in $(find . -name "$ext" -type f 2>/dev/null); do
            if should_skip_file "$file"; then
                continue
            fi
            if grep -q "$OLD_LIB_NAME" "$file" 2>/dev/null; then
                print_status "Updating library names in: $file"
                sed -i.bak "s|$OLD_LIB_NAME|$NEW_LIB_NAME|g" "$file"
                rm -f "$file.bak"
                count=$((count + 1))
            fi
        done
    done
    
    print_success "Updated library names in $count files"
}

# Function to update BUILD.gn files
update_build_files() {
    print_status "Updating BUILD.gn files..."
    
    local count=0
    for file in $(find . -name "BUILD.gn" -o -name "*.gni" -type f 2>/dev/null); do
        if should_skip_file "$file"; then
            continue
        fi
        if grep -q "$OLD_PACKAGE_PATH" "$file" 2>/dev/null; then
            print_status "Updating BUILD file: $file"
            sed -i.bak "s|$OLD_PACKAGE_PATH|$NEW_PACKAGE_PATH|g" "$file"
            rm -f "$file.bak"
            count=$((count + 1))
        fi
    done
    
    print_success "Updated $count BUILD files"
}

# Function to validate changes
validate_changes() {
    print_status "Validating changes..."
    
    local errors=0
    
    # Check for remaining old package references
    local remaining_org_webrtc=$(grep -r "org\.webrtc" . --include="*.java" --include="*.cc" --include="*.h" --include="*.cpp" --include="*.hpp" --include="*.c" --include="*.gn" --include="*.gni" --include="*.xml" --include="*.py" --include="*.sh" --include="*.md" --include="*.txt" --include="*.json" --include="*.properties" 2>/dev/null | grep -v "rename_webrtc_package" | grep -v "test_rename_script" | wc -l || echo "0")
    
    if [ "$remaining_org_webrtc" -gt 0 ]; then
        print_warning "Found $remaining_org_webrtc remaining org.webrtc references"
        errors=$((errors + 1))
    fi
    
    # Check for remaining old path references
    local remaining_org_path=$(grep -r "org/webrtc" . --include="*.java" --include="*.cc" --include="*.h" --include="*.cpp" --include="*.hpp" --include="*.c" --include="*.gn" --include="*.gni" --include="*.xml" --include="*.py" --include="*.sh" --include="*.md" --include="*.txt" --include="*.json" --include="*.properties" 2>/dev/null | grep -v "rename_webrtc_package" | grep -v "test_rename_script" | wc -l || echo "0")
    
    if [ "$remaining_org_path" -gt 0 ]; then
        print_warning "Found $remaining_org_path remaining org/webrtc path references"
        errors=$((errors + 1))
    fi
    
    # Check for remaining JNI function names
    local remaining_jni=$(grep -r "Java_org_webrtc_" . --include="*.java" --include="*.cc" --include="*.h" --include="*.cpp" --include="*.hpp" --include="*.c" --include="*.gn" --include="*.gni" --include="*.xml" --include="*.py" --include="*.sh" --include="*.md" --include="*.txt" --include="*.json" --include="*.properties" 2>/dev/null | grep -v "rename_webrtc_package" | grep -v "test_rename_script" | wc -l || echo "0")
    
    if [ "$remaining_jni" -gt 0 ]; then
        print_warning "Found $remaining_jni remaining Java_org_webrtc_ references"
        errors=$((errors + 1))
    fi
    
    # Check for remaining library names
    local remaining_lib=$(grep -r "libjingle_peerconnection_so" . --include="*.java" --include="*.cc" --include="*.h" --include="*.cpp" --include="*.hpp" --include="*.c" --include="*.gn" --include="*.gni" --include="*.xml" --include="*.py" --include="*.sh" --include="*.md" --include="*.txt" --include="*.json" --include="*.properties" 2>/dev/null | grep -v "rename_webrtc_package" | grep -v "test_rename_script" | wc -l || echo "0")
    
    if [ "$remaining_lib" -gt 0 ]; then
        print_warning "Found $remaining_lib remaining libjingle_peerconnection_so references"
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
    replace_package_declarations
    replace_imports
    replace_package_references
    replace_path_references
    replace_jni_functions
    replace_library_names
    update_build_files
    
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
        exit 0
        ;;
    *)
        main "$@"
        ;;
esac
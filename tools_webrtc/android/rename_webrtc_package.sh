#!/bin/bash

# Rewrite the Android WebRTC Java package from org.webrtc to io.getstream.webrtc.
#
# Run this from the WebRTC src root, after the tree is checked out and before
# the Android build. Pass --no-backup in CI. A synced tree already contains
# third_party and out; those directories are skipped because rewriting them is
# slow and can change unrelated Chromium code.
#
# Usage: ./tools_webrtc/android/rename_webrtc_package.sh --no-backup

set -euo pipefail

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
  echo "[INFO] $1"
}

print_success() {
  echo "[SUCCESS] $1"
}

print_warning() {
  echo "[WARNING] $1"
}

print_error() {
  echo "[ERROR] $1"
}

should_skip_file() {
  local file="$1"
  [[ "$file" == *"rename_webrtc_package"* || "$file" == *.bak ]]
}

find_pruned() {
  find . \
    \( -path './third_party' -o -path './out' -o -path './build' -o -path './.git' -o -path './.cipd' \) -prune \
    -o "$@"
}

find_org_webrtc_dirs() {
  find_pruned -type d -path '*/org/webrtc' -print
}

create_backup() {
  local backup_dir="webrtc_backup_$(date +%Y%m%d_%H%M%S)"
  print_status "Creating backup in ../$backup_dir..."
  cp -R . "../$backup_dir"
  print_success "Backup created at ../$backup_dir"
}

create_new_dirs() {
  print_status "Creating new directory structure..."
  local old_dir new_dir
  while IFS= read -r old_dir; do
    [ -n "$old_dir" ] || continue
    new_dir=${old_dir//$OLD_PACKAGE_PATH/$NEW_PACKAGE_PATH}
    mkdir -p "$new_dir"
  done < <(find_org_webrtc_dirs)
  print_success "Directory structure created"
}

move_java_files() {
  print_status "Moving Java files from org/webrtc to $NEW_PACKAGE_PATH..."
  local old_dir new_dir
  while IFS= read -r old_dir; do
    [ -n "$old_dir" ] || continue
    [ -d "$old_dir" ] || continue
    new_dir=${old_dir//$OLD_PACKAGE_PATH/$NEW_PACKAGE_PATH}
    mkdir -p "$new_dir"
    find "$old_dir" -mindepth 1 -maxdepth 1 -exec mv {} "$new_dir/" \;
  done < <(find_org_webrtc_dirs)
  print_success "Java files moved"
}

cleanup_empty_dirs() {
  print_status "Cleaning up empty org/webrtc directories..."
  local old_dir
  while IFS= read -r old_dir; do
    [ -n "$old_dir" ] || continue
    if [ -d "$old_dir" ] && [ -z "$(ls -A "$old_dir" 2>/dev/null)" ]; then
      rmdir "$old_dir" 2>/dev/null || true
    fi
  done < <(find_org_webrtc_dirs | sort -r)
  print_success "Empty directories cleaned up"
}

replace_all_references() {
  print_status "Replacing package, JNI, and library references..."
  local count=0
  local ext file
  local old_package_esc=${OLD_PACKAGE//./\\.}

  for ext in "${FILE_EXTENSIONS[@]}"; do
    while IFS= read -r -d '' file; do
      if should_skip_file "$file"; then
        continue
      fi
      if ! grep -q -e "$OLD_PACKAGE_PATH" -e "$OLD_PACKAGE" -e "$OLD_JNI_PREFIX" \
        -e "$OLD_LIB_NAME" -e "$OLD_JNI_UNDERSCORE" -e "$BARE_OLD_LIB_NAME" "$file" 2>/dev/null; then
        continue
      fi

      # Bare library name before the lib-prefixed name. The bare token is a
      # substring of libjingle_peerconnection_so, and the reverse order would
      # rewrite the already-renamed library a second time.
      sed -i.bak \
        -e "s|$OLD_PACKAGE_PATH|$NEW_PACKAGE_PATH|g" \
        -e "s|$old_package_esc|$NEW_PACKAGE|g" \
        -e "s|$OLD_JNI_PREFIX|$NEW_JNI_PREFIX|g" \
        -e "s|$BARE_OLD_LIB_NAME|$BARE_NEW_LIB_NAME|g" \
        -e "s|$OLD_LIB_NAME|$NEW_LIB_NAME|g" \
        -e "s|$OLD_JNI_UNDERSCORE|$NEW_JNI_UNDERSCORE|g" \
        "$file"
      rm -f "$file.bak"
      count=$((count + 1))
    done < <(find_pruned -type f -name "$ext" -print0)
  done

  print_success "Updated $count files"
}

collect_matches() {
  local pattern="$1"
  shift
  local includes=()
  local ext
  for ext in "$@"; do
    includes+=(--include="$ext")
  done
  # -F keeps package strings literal. "." in org.webrtc must not be a regex.
  grep -R -I -n -F \
    --exclude-dir=third_party \
    --exclude-dir=out \
    --exclude-dir=build \
    --exclude-dir=.git \
    --exclude-dir=.cipd \
    --exclude='*rename_webrtc_package*' \
    "${includes[@]}" \
    -e "$pattern" . || true
}

validate_changes() {
  print_status "Validating changes..."
  local errors=0
  local exts=(
    "*.java" "*.cc" "*.h" "*.cpp" "*.hpp" "*.c" "*.gn" "*.gni"
    "*.xml" "*.py" "*.sh" "*.md" "*.txt" "*.json" "*.properties"
  )
  local label pattern matches
  local checks=(
    "package references|$OLD_PACKAGE"
    "path references|$OLD_PACKAGE_PATH"
    "JNI prefixes|$OLD_JNI_PREFIX"
    "JNI symbols|$OLD_JNI_UNDERSCORE"
    "library names|$OLD_LIB_NAME"
  )

  for check in "${checks[@]}"; do
    label=${check%%|*}
    pattern=${check#*|}
    matches=$(collect_matches "$pattern" "${exts[@]}")
    if [ -n "$matches" ]; then
      print_warning "Found remaining $label"
      echo "$matches" | head -n 20
      errors=$((errors + 1))
    fi
  done

  # stream_jingle_peerconnection_so still contains the old bare token. Match
  # only occurrences that were not given the stream_ prefix.
  local bare_includes=()
  local ext
  for ext in "${exts[@]}"; do
    bare_includes+=(--include="$ext")
  done
  matches=$(grep -R -I -n -E \
    --exclude-dir=third_party \
    --exclude-dir=out \
    --exclude-dir=build \
    --exclude-dir=.git \
    --exclude-dir=.cipd \
    --exclude='*rename_webrtc_package*' \
    "${bare_includes[@]}" \
    -e "(^|[^_])${BARE_OLD_LIB_NAME}" . || true)
  if [ -n "$matches" ]; then
    print_warning "Found remaining bare library names"
    echo "$matches" | head -n 20
    errors=$((errors + 1))
  fi

  local old_java_files
  old_java_files=$(find_pruned -path '*/org/webrtc/*.java' -type f -print)
  if [ -n "$old_java_files" ]; then
    print_warning "Java files remain under org/webrtc"
    echo "$old_java_files" | head -n 20
    errors=$((errors + 1))
  fi

  if [ "$errors" -eq 0 ]; then
    print_success "All validations passed"
    return 0
  fi
  print_error "Validation found $errors issues"
  return 1
}

main() {
  local skip_backup=false
  if [ "${1:-}" = "--no-backup" ]; then
    skip_backup=true
  fi

  if [ ! -f "BUILD.gn" ] || [ ! -d "sdk" ]; then
    print_error "This script must be run from the WebRTC root directory"
    exit 1
  fi

  print_status "Renaming $OLD_PACKAGE to $NEW_PACKAGE"
  if [ "$skip_backup" = true ]; then
    print_warning "Skipping backup (--no-backup)"
  elif [ -d third_party ] || [ -d out ]; then
    print_warning "Synced tree detected. Skipping backup so third_party is not copied."
  else
    create_backup
  fi

  create_new_dirs
  move_java_files
  cleanup_empty_dirs
  replace_all_references
  validate_changes
  print_success "Package renaming completed"
}

case "${1:-}" in
  --help|-h)
    echo "Usage: $0 [--no-backup]"
    echo "Rename org.webrtc to io.getstream.webrtc in the WebRTC src tree."
    ;;
  --no-backup|"")
    main "$@"
    ;;
  *)
    print_error "Unknown argument: $1"
    exit 1
    ;;
esac

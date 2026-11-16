#!/usr/bin/env python3
"""Compare packaged Android and Apple WebRTC artifacts.

The Release workflow compares the artifacts it just packaged with the
previous GitHub release and adds this table to the release notes. The
same script runs locally and does not compile. Point it at two
directories, archives, or release tags.

  python3 stream_build/scripts/size-diff.py \
      --before /tmp/webrtc-145 --after /tmp/webrtc-156

  python3 stream_build/scripts/size-diff.py \
      --before-tag 145.25.0 --after-tag 156.0.4

A directory may contain libwebrtc.aar and WebRTC.xcframework.zip (or an
extracted WebRTC.xcframework). Archive rows are the file on disk. Library
and framework rows are the uncompressed bytes a device installs.
"""

import argparse
import os
import subprocess
import sys
import zipfile

ANDROID_AAR = "libwebrtc.aar"
APPLE_ZIP = "WebRTC.xcframework.zip"
COMMENT_MARKER = "<!-- webrtc-size-diff -->"


def mb(n):
    return f"{n / 1024 / 1024:.2f} MB"


def signed_mb(n):
    return f"{n / 1024 / 1024:+.2f} MB"


def measure_zip(path, prefix):
    sizes = {}
    with zipfile.ZipFile(path) as archive:
        for info in archive.infolist():
            if info.is_dir() or info.file_size == 0:
                continue
            sizes[f"{prefix}{info.filename}"] = info.file_size
    return sizes


def is_framework_executable(name):
    return name.endswith(".framework/WebRTC") or name.endswith(
        ".framework/Versions/A/WebRTC")


def framework_slices(entry_sizes):
    """Map xcframework slice name to the uncompressed framework executable."""
    binaries = []
    for name, size in entry_sizes.items():
        if not is_framework_executable(name):
            continue
        binaries.append((name, size))
    versioned = [item for item in binaries if "/Versions/A/" in item[0]]
    chosen = versioned or binaries
    slices = {}
    for name, size in chosen:
        parts = name.split("/")
        slice_name = ""
        for i, part in enumerate(parts):
            if part.endswith(".framework") and i:
                slice_name = parts[i - 1]
                break
        if slice_name:
            slices[slice_name] = size
    return slices


def measure_aar(path):
    rows = {ANDROID_AAR: os.path.getsize(path)}
    entries = measure_zip(path, "")
    if "classes.jar" in entries:
        rows["classes.jar"] = entries["classes.jar"]
    for name, size in entries.items():
        if name.startswith("jni/") and name.endswith(".so"):
            rows[name] = size
    return rows


def measure_apple_zip(path):
    rows = {APPLE_ZIP: os.path.getsize(path)}
    slices = framework_slices(measure_zip(path, ""))
    for name, size in slices.items():
        rows[f"apple:{name}"] = size
    return rows


def measure_apple_dir(path):
    rows = {}
    for dirpath, _, files in os.walk(path):
        for name in files:
            full = os.path.join(dirpath, name)
            if os.path.islink(full):
                continue
            rel = os.path.relpath(full, path)
            if not is_framework_executable(rel):
                continue
            if "/Versions/" in rel and "/Versions/A/" not in rel:
                continue
            parts = rel.split(os.sep)
            slice_name = ""
            for i, part in enumerate(parts):
                if part.endswith(".framework") and i:
                    slice_name = parts[i - 1]
                    break
            if slice_name:
                rows[f"apple:{slice_name}"] = os.path.getsize(full)
    return rows


def measure(path):
    """Measure one side. path is a file, a directory, or a release tag."""
    if os.path.isdir(path):
        rows = {}
        aar = os.path.join(path, ANDROID_AAR)
        apple = os.path.join(path, APPLE_ZIP)
        framework = os.path.join(path, "WebRTC.xcframework")
        if os.path.isfile(aar):
            rows.update(measure_aar(aar))
        if os.path.isfile(apple):
            rows.update(measure_apple_zip(apple))
        elif os.path.isdir(framework):
            rows.update(measure_apple_dir(framework))
        if not rows:
            raise SystemExit(f"{path}: no {ANDROID_AAR} or {APPLE_ZIP}")
        return rows
    if os.path.isfile(path):
        if path.endswith(".aar"):
            return measure_aar(path)
        if path.endswith(".zip"):
            return measure_apple_zip(path)
        raise SystemExit(f"{path}: expected an .aar or .zip")
    raise SystemExit(f"{path}: not a file or directory")


def download_release(tag, dest, repo):
    os.makedirs(dest, exist_ok=True)
    cmd = [
        "gh", "release", "download", tag,
        "--repo", repo,
        "--clobber",
        "--dir", dest,
        "--pattern", ANDROID_AAR,
        "--pattern", APPLE_ZIP,
    ]
    subprocess.run(cmd, check=True)
    return dest


def release_tags(repo, limit):
    raw = subprocess.check_output(
        [
            "gh", "release", "list",
            "--repo", repo,
            "--limit", str(limit),
            "--json", "tagName",
        ],
        text=True,
    )
    import json
    return [item["tagName"] for item in json.loads(raw)]


def row_sort_key(name):
    order = {
        ANDROID_AAR: (0, ""),
        "classes.jar": (1, ""),
    }
    if name in order:
        return order[name]
    if name.startswith("jni/"):
        return (2, name)
    if name == APPLE_ZIP:
        return (3, "")
    if name.startswith("apple:"):
        return (4, name)
    return (9, name)


def display_name(name):
    if name.startswith("apple:"):
        return f"{name.split(':', 1)[1]} WebRTC"
    return name


def render(before_label, after_label, before, after):
    lines = [
        COMMENT_MARKER,
        "## Artifact size diff",
        "",
        f"Before: `{before_label}`",
        "",
        f"After: `{after_label}`",
        "",
        "Archive rows are the file size. Library rows are the uncompressed",
        "bytes stored in the archive, which is what a device installs.",
        "",
        "| Measurement | Before | After | Difference |",
        "|---|---:|---:|---:|",
    ]
    names = sorted(set(before) | set(after), key=row_sort_key)
    for name in names:
        left = before.get(name)
        right = after.get(name)
        left_cell = mb(left) if left is not None else "—"
        right_cell = mb(right) if right is not None else "—"
        if left is None or right is None:
            diff = "—"
        else:
            diff = signed_mb(right - left)
        lines.append(
            f"| {display_name(name)} | {left_cell} | {right_cell} | {diff} |"
        )
    lines.append("")
    return "\n".join(lines)


def resolve_side(path, tag, dest, repo):
    if path and tag:
        raise SystemExit("pass a path or a tag, not both")
    if path:
        return path, measure(path)
    if tag:
        return tag, measure(download_release(tag, dest, repo))
    raise SystemExit("missing before/after path or tag")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--before", help="File or directory for the before column")
    parser.add_argument("--after", help="File or directory for the after column")
    parser.add_argument("--before-tag", help="GitHub release tag for the before column")
    parser.add_argument("--after-tag", help="GitHub release tag for the after column")
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", "GetStream/webrtc"))
    parser.add_argument("--output", help="Write the markdown table to this file too")
    args = parser.parse_args()

    before_tag = args.before_tag
    after_tag = args.after_tag
    need_before = not args.before and not before_tag
    need_after = not args.after and not after_tag
    if need_before or need_after:
        tags = release_tags(args.repo, 20)
        if need_before and need_after:
            if len(tags) < 2:
                raise SystemExit(f"{args.repo} needs two releases to compare")
            after_tag, before_tag = tags[0], tags[1]
        elif need_before:
            older = [tag for tag in tags if tag != after_tag]
            if not older:
                raise SystemExit(f"no release before {after_tag}")
            before_tag = older[0]
        else:
            if not tags:
                raise SystemExit(f"{args.repo} has no releases")
            after_tag = tags[0]

    work = os.path.join(
        os.environ.get("RUNNER_TEMP", "/tmp"),
        "webrtc-size-diff",
    )
    before_label, before = resolve_side(
        args.before, before_tag, os.path.join(work, "before"), args.repo)
    after_label, after = resolve_side(
        args.after, after_tag, os.path.join(work, "after"), args.repo)
    table = render(before_label, after_label, before, after)
    sys.stdout.write(table)
    if args.output:
        with open(args.output, "w") as handle:
            handle.write(table)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as handle:
            handle.write(table)


if __name__ == "__main__":
    main()

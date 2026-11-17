#!/usr/bin/env python3
"""Compare packaged Android and Apple WebRTC artifacts.

The Release workflow compares the artifacts it just packaged with the
newest stable GitHub release and adds this table to the release notes.
The build being published may be a prerelease. The baseline is not.
The same script runs locally and does not compile. Point it at two
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
import shutil
import subprocess
import sys
import tempfile
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


def slice_name(path):
    parts = path.split("/")
    for i, part in enumerate(parts):
        if part.endswith(".framework") and i:
            return parts[i - 1]
    return ""


def framework_slices(entry_sizes):
    """Map each xcframework slice to its uncompressed executable.

    A combined archive has unversioned iOS executables and versioned
    macOS executables. Prefer Versions/A only inside the slice that has
    one, so a versioned macOS binary does not drop the iOS slices.
    """
    grouped = {}
    for name, size in entry_sizes.items():
        if not is_framework_executable(name):
            continue
        if "/Versions/" in name and "/Versions/A/" not in name:
            continue
        name_of_slice = slice_name(name)
        if not name_of_slice:
            continue
        grouped.setdefault(name_of_slice, []).append((name, size))
    slices = {}
    for name_of_slice, binaries in grouped.items():
        versioned = [item for item in binaries if "/Versions/A/" in item[0]]
        chosen = versioned[0] if versioned else binaries[0]
        slices[name_of_slice] = chosen[1]
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
    entries = {}
    for dirpath, _, files in os.walk(path):
        for name in files:
            full = os.path.join(dirpath, name)
            if os.path.islink(full):
                continue
            rel = os.path.relpath(full, path).replace(os.sep, "/")
            entries[rel] = os.path.getsize(full)
    return {
        f"apple:{name}": size
        for name, size in framework_slices(entries).items()
    }


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


def releases(repo, limit):
    raw = subprocess.check_output(
        [
            "gh", "release", "list",
            "--repo", repo,
            "--limit", str(limit),
            "--exclude-drafts",
            "--json", "tagName,isPrerelease",
        ],
        text=True,
    )
    import json
    return json.loads(raw)


def previous_stable(releases, exclude=""):
    """Newest stable tag. The release being built may be a prerelease; exclude skips it when it is already published and stable."""
    for item in releases:
        if item.get("isPrerelease"):
            continue
        tag = item.get("tagName") or ""
        if not tag or tag == exclude:
            continue
        return tag
    return ""


def selftest():
    found = [
        {"tagName": "156.0.5", "isPrerelease": False},
        {"tagName": "156.0.4", "isPrerelease": True},
        {"tagName": "156.0.3", "isPrerelease": True},
        {"tagName": "145.25.0", "isPrerelease": False},
    ]
    if previous_stable(found) != "156.0.5":
        raise SystemExit("latest stable should be 156.0.5")
    if previous_stable(found, exclude="156.0.5") != "145.25.0":
        raise SystemExit("stable before 156.0.5 should skip the prereleases")
    publishing = [
        {"tagName": "156.0.6", "isPrerelease": True},
        {"tagName": "156.0.5", "isPrerelease": False},
        {"tagName": "156.0.4", "isPrerelease": True},
        {"tagName": "145.25.0", "isPrerelease": False},
    ]
    if previous_stable(publishing, exclude="156.0.6") != "156.0.5":
        raise SystemExit("a prerelease build should compare with the latest stable release")
    if previous_stable([{"tagName": "156.0.4", "isPrerelease": True}]) != "":
        raise SystemExit("prereleases alone are not a baseline")
    print("size-diff selftest passed")


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
    parser.add_argument("--selftest", action="store_true", help="Run the baseline selector checks")
    args = parser.parse_args()
    if args.selftest:
        selftest()
        return

    before_tag = args.before_tag
    after_tag = args.after_tag
    need_before = not args.before and not before_tag
    need_after = not args.after and not after_tag
    if need_before or need_after:
        found = releases(args.repo, 50)
        if need_after:
            if not found:
                raise SystemExit(f"{args.repo} has no releases")
            after_tag = found[0]["tagName"]
        if need_before:
            before_tag = previous_stable(found, exclude=after_tag or "")
            if not before_tag:
                raise SystemExit(f"{args.repo} has no stable release to compare")

    work = tempfile.mkdtemp(prefix="webrtc-size-diff-")
    try:
        before_label, before = resolve_side(
            args.before, before_tag, os.path.join(work, "before"), args.repo)
        after_label, after = resolve_side(
            args.after, after_tag, os.path.join(work, "after"), args.repo)
        table = render(before_label, after_label, before, after)
    finally:
        shutil.rmtree(work, ignore_errors=True)
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

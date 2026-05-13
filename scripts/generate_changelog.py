#!/usr/bin/env python3
"""Generate a categorized Markdown changelog draft from a git revision range.

By default uses ``git log --first-parent`` so fork release-line commits dominate.

Use ``--merge-diff MERGE`` to list commits introduced by a single merge commit
(``git log MERGE^1..MERGE^2``), i.e. the full upstream branch merged in.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path


@dataclass(frozen=True)
class Commit:
    hash: str
    short: str
    subject: str
    files: tuple[str, ...]


def _run_git(args: list[str], cwd: Path) -> str:
    try:
        return subprocess.check_output(
            ["git", *args],
            cwd=cwd,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
    except subprocess.CalledProcessError as e:
        print(e.output or str(e), file=sys.stderr)
        raise SystemExit(1) from e


def _resolve_ref(cwd: Path, ref: str) -> str:
    return _run_git(["rev-parse", "--verify", f"{ref}^{{commit}}"], cwd).strip()


def _parse_log_name_only(text: str) -> list[Commit]:
    """Parse ``git log --pretty=tformat:'%H\\t%s' --name-only`` output."""
    commits: list[Commit] = []
    cur_hash: str | None = None
    cur_subject: str | None = None
    cur_files: list[str] = []

    def flush() -> None:
        nonlocal cur_hash, cur_subject, cur_files
        if cur_hash is not None:
            commits.append(
                Commit(
                    hash=cur_hash,
                    short=cur_hash[:12],
                    subject=cur_subject or "",
                    files=tuple(cur_files),
                )
            )
        cur_hash = cur_subject = None
        cur_files = []

    for line in text.splitlines():
        if "\t" in line:
            maybe_hash, rest = line.split("\t", 1)
            h = maybe_hash.strip()
            if len(h) == 40 and re.fullmatch(r"[0-9a-f]{40}", h):
                flush()
                cur_hash = h
                cur_subject = rest
                continue
        if line.strip() and cur_hash is not None:
            cur_files.append(line.strip())
    flush()
    return commits


def _list_commits(
    cwd: Path,
    range_spec: str,
    *,
    first_parent: bool,
) -> list[Commit]:
    cmd = [
        "log",
        "--reverse",
        "--pretty=tformat:%H\t%s",
        "--name-only",
        range_spec,
    ]
    if first_parent:
        cmd.insert(1, "--first-parent")
    raw = _run_git(cmd, cwd)
    return _parse_log_name_only(raw)


def _merge_parent_hashes(cwd: Path, merge_commit: str) -> tuple[str, str]:
    """Return (first parent, second parent) for a two-parent merge commit."""
    merge_full = _resolve_ref(cwd, merge_commit)
    parents = _run_git(["show", "-s", "--format=%P", merge_full], cwd).strip().split()
    if len(parents) != 2:
        print(
            f"error: {merge_commit} must be a two-parent merge commit "
            f"(expected 2 parents, got {len(parents)})",
            file=sys.stderr,
        )
        raise SystemExit(1)
    return parents[0], parents[1]


def _subject_lower(s: str) -> str:
    return s.lower()


def _is_public_api_touch(files: tuple[str, ...]) -> bool:
    for f in files:
        if f.startswith("sdk/objc/api/"):
            return True
        if f.startswith("sdk/android/api/"):
            return True
        if f.startswith("api/") and f.endswith(".h"):
            return True
        if "/java/org/webrtc/" in f.replace("\\", "/"):
            return True
    return False


def _is_upstream_merge(subject: str) -> bool:
    s = subject
    if re.search(r"merge\s+official\s+webrtc", _subject_lower(s)):
        return True
    if re.search(r"sync\s+with\s+livekit", _subject_lower(s)):
        return True
    if re.search(r"baseline\s+into\s+.*fork", _subject_lower(s)):
        return True
    if re.search(r"^\s*\d+\.\d+\s+to\s+main\b", _subject_lower(s)):
        return True
    if re.search(r"\badd\s+missed\s+merges\b", _subject_lower(s)):
        return True
    return False


def _path_looks_like_test_or_ci(path: str) -> bool:
    fl = path.replace("\\", "/").lower()
    if fl.startswith(".github/"):
        return True
    if "/unittests/" in fl or fl.endswith("_unittest.cc"):
        return True
    if fl.endswith("_xctest.mm") or fl.endswith("_xctest.m"):
        return True
    if "/tests/" in fl or fl.startswith("test/"):
        return True
    if "mock_" in fl or "/mock/" in fl or "fake_" in fl:
        return True
    if fl.endswith("_test.cc") or fl.endswith("_tests.cc"):
        return True
    return False


def _all_paths_are_test_or_ci_only(files: tuple[str, ...]) -> bool:
    if not files:
        return False
    return all(_path_looks_like_test_or_ci(f) for f in files)


def _is_test_internal(subject: str, files: tuple[str, ...]) -> bool:
    sl = _subject_lower(subject)
    if re.match(r"^\s*\[ci\]", sl):
        return True
    if re.search(r"fix\s+tests\b", sl):
        return True
    if "merge conflict" in sl:
        return True
    if (
        re.search(r"\brefactor\b", sl)
        and "[enhancement]" not in sl
        and not re.search(r"build fixes", sl)
        and "refactoring to reduce merge conflict" in sl
    ):
        return True
    return _all_paths_are_test_or_ci_only(files)


def _is_platform_build(subject: str, files: tuple[str, ...]) -> bool:
    sl = _subject_lower(subject)
    keywords = (
        "build fix",
        "build fixes",
        "compilation",
        " fix includes",
        "includes in ",
        "gitignore",
        " gn ",
        "build.gn",
        "deps",
    )
    if any(k in sl for k in keywords):
        return True
    if re.search(r"\bfix\s+includes\b", sl):
        return True
    for f in files:
        base = Path(f).name
        if base in ("BUILD.gn", "DEPS", "webrtc.gni", ".gitignore"):
            return True
        if f.startswith("build_overrides/"):
            return True
    return False


def _is_feature(subject: str) -> bool:
    s = subject.strip()
    sl = _subject_lower(s)
    if sl.startswith("[enhancement]"):
        return True
    if sl.startswith("add "):
        return True
    if sl.startswith("expose "):
        return True
    if " add support for " in sl:
        return True
    if sl.startswith("implement "):
        return True
    return False


def _is_fix(subject: str) -> bool:
    s = subject.strip()
    sl = _subject_lower(s)
    if sl.startswith("[fix]"):
        return True
    if sl.startswith("fix:"):
        return True
    if sl.startswith("fix "):
        return True
    if "crash" in sl or "teardown" in sl or "dealloc" in sl:
        return True
    if "preserve " in sl or "preserves " in sl:
        return True
    if "missing frames" in sl:
        return True
    if "prompts showing" in sl:
        return True
    return False


_LARGE_CHANGE_MIN_FILES = 200


def _categorize(c: Commit) -> str:
    """Return one section key per plan priority."""
    subj = c.subject
    files = c.files

    if _is_upstream_merge(subj):
        return "upstream"
    if len(files) >= _LARGE_CHANGE_MIN_FILES:
        return "other"
    if _is_test_internal(subj, files):
        return "tests_internal"
    if _is_public_api_touch(files):
        return "breaking_review"
    if _is_feature(subj):
        return "features"
    if _is_fix(subj):
        return "fixes"
    if _is_platform_build(subj, files):
        return "platform"
    return "other"


def _format_line(c: Commit) -> str:
    return f"- `{c.short}` {c.subject}"


def _write_changelog(
    out: Path,
    title_from: str,
    title_to: str,
    commits: list[Commit],
    *,
    range_note: str,
) -> None:
    sections: dict[str, list[Commit]] = {
        "breaking_review": [],
        "upstream": [],
        "features": [],
        "fixes": [],
        "platform": [],
        "tests_internal": [],
        "other": [],
    }
    for c in commits:
        sections[_categorize(c)].append(c)

    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

    lines: list[str] = [
        f"# Changelog draft: `{title_from}` → `{title_to}`",
        "",
        f"_Generated {now} by `scripts/generate_changelog.py`._",
        range_note,
        "",
        "## Breaking change review",
        "",
        "_Commits touching public headers or packaged API paths. Confirm externally visible behavior before release._",
        "",
    ]
    if sections["breaking_review"]:
        for c in sections["breaking_review"]:
            lines.append(_format_line(c))
    else:
        lines.append("_None auto-flagged._")
    lines.extend(
        [
            "",
            "## Upstream WebRTC merge",
            "",
        ]
    )
    if sections["upstream"]:
        for c in sections["upstream"]:
            lines.append(_format_line(c))
    else:
        lines.append("_None auto-detected._")

    lines.extend(["", "## Features", ""])
    if sections["features"]:
        for c in sections["features"]:
            lines.append(_format_line(c))
    else:
        lines.append("_None._")

    lines.extend(["", "## Fixes", ""])
    if sections["fixes"]:
        for c in sections["fixes"]:
            lines.append(_format_line(c))
    else:
        lines.append("_None._")

    lines.extend(["", "## Platform / build", ""])
    if sections["platform"]:
        for c in sections["platform"]:
            lines.append(_format_line(c))
    else:
        lines.append("_None._")

    lines.extend(["", "## Tests / internal", ""])
    if sections["tests_internal"]:
        for c in sections["tests_internal"]:
            lines.append(_format_line(c))
    else:
        lines.append("_None._")

    lines.extend(["", "## Other changes", ""])
    if sections["other"]:
        lines.append(
            "_Includes very large diffs (auto: ≥200 files) that should be summarized manually rather than reviewed line-by-line._"
        )
        lines.append("")
        for c in sections["other"]:
            lines.append(_format_line(c))
    else:
        lines.append("_None._")

    lines.append("")
    out.write_text("\n".join(lines), encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Generate a categorized Markdown changelog from git history."
    )
    parser.add_argument(
        "--merge-diff",
        metavar="COMMIT",
        default=None,
        help=(
            "List commits introduced by this two-parent merge: "
            "equivalent to `git log COMMIT^1..COMMIT^2`. "
            "When set, --from/--to are ignored."
        ),
    )
    parser.add_argument(
        "--from",
        dest="from_ref",
        default=None,
        help="Start ref (exclusive), e.g. tag m137.5 (not used with --merge-diff)",
    )
    parser.add_argument(
        "--to",
        dest="to_ref",
        default="HEAD",
        help="End ref (inclusive), default HEAD (not used with --merge-diff)",
    )
    parser.add_argument(
        "--output",
        "-o",
        required=True,
        type=Path,
        help="Output Markdown file path",
    )
    parser.add_argument(
        "--repo",
        type=Path,
        default=None,
        help="Git repository root (default: parent of this script's directory)",
    )
    args = parser.parse_args()

    cwd = args.repo or Path(__file__).resolve().parent.parent

    if args.merge_diff:
        if args.from_ref is not None:
            parser.error("--from cannot be used with --merge-diff")
        merge_full = _resolve_ref(cwd, args.merge_diff)
        p1, p2 = _merge_parent_hashes(cwd, args.merge_diff)
        range_spec = f"{p1}..{p2}"
        commits = _list_commits(cwd, range_spec, first_parent=False)
        title_from = f"{args.merge_diff}^1"
        title_to = f"{args.merge_diff}^2"
        from_full, to_full = p1, p2
        range_note = (
            f"_Same commits as `git log {args.merge_diff}^1..{args.merge_diff}^2` "
            f"(merge `{merge_full[:12]}`; full merged-branch history, not `--first-parent`). "
            f"Tips of ^1 and ^2: `{p1[:12]}` … `{p2[:12]}`._"
        )
    else:
        if not args.from_ref:
            parser.error("the following arguments are required: --from (unless using --merge-diff)")
        from_full = _resolve_ref(cwd, args.from_ref)
        to_full = _resolve_ref(cwd, args.to_ref)
        range_spec = f"{from_full}..{to_full}"
        commits = _list_commits(cwd, range_spec, first_parent=True)
        title_from = args.from_ref
        title_to = args.to_ref
        range_note = (
            f"_Range: `{from_full[:12]}` … `{to_full[:12]}` "
            f"(`git log --first-parent`)._"
        )

    _write_changelog(
        args.output,
        title_from,
        title_to,
        commits,
        range_note=range_note,
    )
    print(f"Wrote {len(commits)} commits to {args.output}", file=sys.stderr)


if __name__ == "__main__":
    main()

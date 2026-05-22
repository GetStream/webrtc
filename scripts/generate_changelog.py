#!/usr/bin/env python3
"""Generate a categorized Markdown changelog draft from a git revision range.

By default uses ``git log --first-parent`` so fork release-line commits dominate.

Use ``--merge-diff MERGE`` to list commits introduced by a single merge commit
(``git log MERGE^1..MERGE^2``), i.e. the full upstream branch merged in.

Use ``--format migration`` with ``--upstream-from`` / ``--upstream-to`` for
release-note style changelogs derived from git history (no hardcoded release data).
"""

from __future__ import annotations

import argparse
import json
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

_PR_NUMBER_RE = re.compile(r"\(#(\d+)\)\s*$")
_UPGRADE_WEBRTC_RE = re.compile(r"upgrade\s+to\s+webrtc\s+m\d+", re.I)

# (group key, section title, summary blurb, subject matcher)
_UPSTREAM_GROUP_RULES: tuple[tuple[str, str, str, re.Pattern[str]], ...] = (
    (
        "chromium_rolls",
        "Chromium depot rolls",
        "Chromium revision rolls keeping third-party dependencies aligned with the target WebRTC milestone.",
        re.compile(r"^Roll chromium", re.I),
    ),
    (
        "webrtc_milestone",
        "WebRTC milestone sync",
        "Upstream WebRTC snapshot version bumps while integrating the release branch.",
        re.compile(r"^Update WebRTC code version", re.I),
    ),
    (
        "reverts",
        "Reverts",
        "Reverted upstream changes that were backed out before the fork merge landed.",
        re.compile(r"^Revert ", re.I),
    ),
    (
        "congestion_control",
        "Congestion control & bandwidth estimation",
        "Scream/TWCC/L4S and related bandwidth-estimation, policing, and experiment work.",
        re.compile(
            r"Scream|TWCC|L4S|congestion control|CC negotiation|traffic policing|"
            r"congestion control algorithm|REMB",
            re.I,
        ),
    ),
    (
        "peerconnection_signaling",
        "PeerConnection, SDP & transceivers",
        "PeerConnection API cleanup, SDP helpers, transceiver lifecycle, and unified communications trials.",
        re.compile(
            r"PeerConnection|RtpTransceiver|libjingle|api:api|transceiver|"
            r"CreateDataChannel|sdp_|SdpPayload|unified communications|StreamParams|"
            r"Cricket|ice lite",
            re.I,
        ),
    ),
    (
        "rtp_transport_metrics",
        "RTP, RTX & transport",
        "RTP send path, RTX logging, DTLS/STUN timing, injectable transports, and timestamp handling.",
        re.compile(
            r"RtpTransport|DTLS|STUN|RTX|TimestampExtrapolator|RtpSender|"
            r"SendRtp|RtcEventLog|header extension",
            re.I,
        ),
    ),
    (
        "ios_sdk",
        "iOS / ObjC SDK",
        "Objective-C SDK wrappers, guards, and platform session adapters.",
        re.compile(r"^sdk:|objc|RTC_OBJC|IOS\b", re.I),
    ),
    (
        "audio",
        "Audio capture & encoding",
        "Audio device/session integration, encoders, and capture/send-path behavior.",
        re.compile(
            r"Audio|AAudio|speech level|AudioEncoder|audio_device|"
            r"RTCNativeAudioSession|SendRtpAudio",
            re.I,
        ),
    ),
    (
        "video",
        "Video pipeline",
        "Video receivers, frame drop policy, instrumentation, and capturer/desktop APIs.",
        re.compile(
            r"Video|frame drop|EncodedImage|resolution scaling|FrameBuffer|"
            r"FrameInstrumentation|Capturer|desktop",
            re.I,
        ),
    ),
    (
        "data_channel",
        "Data channels & SCTP",
        "SCTP/data-channel send semantics and transport teardown ordering.",
        re.compile(r"DataChannel|Sctp|sctp_", re.I),
    ),
    (
        "build_toolchain",
        "Build, GN & toolchain",
        "GN dependency cleanup, C++ standard/config bots, and compile-hygiene changes.",
        re.compile(
            r"^build:|BUILD\.gn|C\+\+23|gn_check|WAIT macro|std::atomic|"
            r"MB config|std::string|absl::string_view|Namespace cleanup",
            re.I,
        ),
    ),
    (
        "tests_ci",
        "Tests, deflake & benchmarks",
        "Unit/integration test updates, deflaking, and benchmark harness work.",
        re.compile(
            r"deflake|unittest|benchmark|test_flags|Test more|Add tests for|"
            r"Add a test_flags|Add test for",
            re.I,
        ),
    ),
    (
        "documentation",
        "Documentation & tooling notes",
        "Docs and developer-facing notes bundled with the upstream drop.",
        re.compile(r"\.md\b|GEMINI|eventlog visualizer|implementation_basics", re.I),
    ),
)

_UPSTREAM_GROUP_ORDER = [rule[0] for rule in _UPSTREAM_GROUP_RULES] + ["misc"]

_UPSTREAM_GROUP_TITLES = {key: title for key, title, _, _ in _UPSTREAM_GROUP_RULES}
_UPSTREAM_GROUP_TITLES["misc"] = "Other upstream changes"
_UPSTREAM_GROUP_SUMMARIES = {key: summary for key, _, summary, _ in _UPSTREAM_GROUP_RULES}
_UPSTREAM_GROUP_SUMMARIES["misc"] = (
    "Additional upstream commits not matching a focused area above."
)


def _extract_pr_number(subject: str) -> int | None:
    m = _PR_NUMBER_RE.search(subject.strip())
    return int(m.group(1)) if m else None


def _should_expand_upstream(c: Commit) -> bool:
    if _is_upstream_merge(c.subject):
        return True
    if _UPGRADE_WEBRTC_RE.search(c.subject):
        return True
    if len(c.files) >= _LARGE_CHANGE_MIN_FILES:
        return True
    return False


def _classify_upstream_subject(subject: str) -> str:
    for key, _, _, pattern in _UPSTREAM_GROUP_RULES:
        if pattern.search(subject):
            return key
    return "misc"


def _group_upstream_subjects(subjects: list[str]) -> dict[str, list[str]]:
    grouped: dict[str, list[str]] = {key: [] for key in _UPSTREAM_GROUP_ORDER}
    for subject in subjects:
        grouped[_classify_upstream_subject(subject)].append(subject)
    return {key: items for key, items in grouped.items() if items}


def _chromium_roll_detail(subjects: list[str]) -> str:
    revs: list[str] = []
    for s in subjects:
        m = re.search(r"\((\d+:\d+)\)", s)
        if m:
            revs.append(m.group(1))
    if not revs:
        return ""
    if len(revs) == 1:
        return f" Chromium revision band `{revs[0]}`."
    return f" Chromium revision bands from `{revs[0]}` through `{revs[-1]}` ({len(subjects)} rolls)."


def _group_summary(key: str, subjects: list[str]) -> str:
    base = _UPSTREAM_GROUP_SUMMARIES[key]
    if key == "chromium_rolls":
        return base + _chromium_roll_detail(subjects)
    if key == "webrtc_milestone" and subjects:
        return f"{base} ({len(subjects)} snapshot bumps)."
    if key == "reverts" and subjects:
        return f"{base} ({len(subjects)} reverts)."
    return base


def _fetch_github_pr_subjects(cwd: Path, pr_number: int) -> list[str] | None:
    try:
        raw = subprocess.check_output(
            [
                "gh",
                "pr",
                "view",
                str(pr_number),
                "--json",
                "commits",
            ],
            cwd=cwd,
            stderr=subprocess.DEVNULL,
            text=True,
            encoding="utf-8",
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None
    try:
        data = json.loads(raw)
        commits = data.get("commits") or []
        return [
            (c.get("messageHeadline") or "").strip()
            for c in commits
            if (c.get("messageHeadline") or "").strip()
        ]
    except (json.JSONDecodeError, TypeError):
        return None


def _expand_upstream_subjects(cwd: Path, c: Commit) -> tuple[list[str], str]:
    """Return (subjects, source note) for an upstream/large commit."""
    try:
        parents = _run_git(["show", "-s", "--format=%P", c.hash], cwd).strip().split()
    except SystemExit:
        parents = []

    if len(parents) == 2:
        range_spec = f"{parents[0]}..{parents[1]}"
        inner = _list_commits(cwd, range_spec, first_parent=False)
        return [x.subject for x in inner], (
            f"_Expanded via `git log {c.short}^1..{c.short}^2` "
            f"({len(inner)} commits)._"
        )

    pr_number = _extract_pr_number(c.subject)
    if pr_number is not None:
        pr_subjects = _fetch_github_pr_subjects(cwd, pr_number)
        if pr_subjects:
            return pr_subjects, (
                f"_Expanded from GitHub PR #{pr_number} "
                f"({len(pr_subjects)} commits; squash merge on fork)._"
            )

    return [], "_Could not expand (not a merge commit and PR lookup failed)._"


def _fork_integration_summary(files: tuple[str, ...]) -> list[str]:
    """Short bullets for fork-only paths in a squashed upstream upgrade."""
    if not files:
        return []
    bullets: list[str] = []
    paths = [f.replace("\\", "/") for f in files]
    if any(p.startswith(".github/") for p in paths):
        bullets.append(
            "CI/publish workflows and composite actions updated for the new milestone."
        )
    if any("frame_crypto" in p or "FrameCryptor" in p for p in paths):
        bullets.append("Frame cryptor / E2EE API sources adjusted for m145.")
    if any("audio_device" in p for p in paths):
        bullets.append("Audio device module and test hooks aligned with upstream ADM changes.")
    if any("objc_desktop" in p or "desktop_capture" in p for p in paths):
        bullets.append("iOS desktop capture APIs refreshed for the ObjC SDK layer.")
    if any(p.endswith("webrtc.gni") or p.endswith("sdk/BUILD.gn") for p in paths):
        bullets.append("GN build config (`webrtc.gni`, `sdk/BUILD.gn`) updated for the release line.")
    if len(bullets) < 2:
        bullets.append(
            f"Fork carries {len(files)} integration paths on top of the upstream snapshot."
        )
    return bullets


def _format_upstream_groups(
    lines: list[str],
    c: Commit,
    grouped: dict[str, list[str]],
    *,
    source_note: str,
    max_examples: int = 4,
) -> None:
    lines.append(f"#### `{c.short}` {c.subject}")
    lines.append("")
    lines.append(source_note)
    if len(c.files) > 0 and len(c.files) < _LARGE_CHANGE_MIN_FILES:
        lines.append(
            f"_Fork-visible diff for this squash: {len(c.files)} paths "
            f"(CI, SDK, crypto, audio device, etc.)._"
        )
        fork_notes = _fork_integration_summary(c.files)
        if fork_notes:
            lines.append("")
            lines.append("**Fork integration (this repo)**")
            lines.append("")
            for note in fork_notes:
                lines.append(f"- {note}")
    lines.append("")
    total = sum(len(v) for v in grouped.values())
    lines.append(f"**{total} upstream commits** grouped by area:")
    lines.append("")
    for key in _UPSTREAM_GROUP_ORDER:
        subjects = grouped.get(key)
        if not subjects:
            continue
        lines.append(f"##### {_UPSTREAM_GROUP_TITLES[key]} ({len(subjects)})")
        lines.append("")
        lines.append(_group_summary(key, subjects))
        lines.append("")
        for subject in subjects[:max_examples]:
            lines.append(f"- {subject}")
        remaining = len(subjects) - max_examples
        if remaining > 0:
            lines.append(f"- _…and {remaining} more in this group._")
        lines.append("")


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


_MIGRATION_CATEGORY_ROWS: tuple[tuple[str, str], ...] = (
    ("Audio", "audio"),
    ("Video and Codecs", "video_codecs"),
    ("Desktop Capture", "desktop_capture"),
    ("PeerConnection and SDP", "peerconnection_sdp"),
    ("Transport and Networking", "transport"),
    ("Stats and Metrics", "stats_metrics"),
    ("Security and Robustness", "security"),
    ("API and SDK", "api_sdk"),
    ("Tests and Reliability", "tests"),
    ("Build and Infrastructure", "build"),
    ("Cleanup and Modernization", "cleanup"),
    ("Reverts and Relands", "reverts_relands"),
    ("Rolls and Versioning", "rolls_versioning"),
    ("General", "general"),
)

_MIGRATION_CATEGORY_RULES: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("rolls_versioning", re.compile(r"^Roll |^Update WebRTC code version", re.I)),
    ("reverts_relands", re.compile(r"^Revert |\bReland\b", re.I)),
    ("desktop_capture", re.compile(
        r"desktop|screencast|wayland|PowerPoint|cursor_embedded|slideshow", re.I
    )),
    ("stats_metrics", re.compile(r"stats|RTCStats|UMA|metric|eventlog|EventLog", re.I)),
    ("security", re.compile(
        r"SSL|certificate|thread.?safe|RTC_GUARDED|crash|TURN port|validation|BIO", re.I
    )),
    ("peerconnection_sdp", re.compile(
        r"PeerConnection|RtpTransceiver|SDP |SdpOffer|BaseChannel|munging|"
        r"CodecPreferences|CreateChannel",
        re.I,
    )),
    ("transport", re.compile(
        r"RTP|RTCP|ICE|DTLS|SCTP|transport|NACK|RTX|pacing|STUN|TURN|Probe|"
        r"congestion|Scream|TWCC|L4S|Packet",
        re.I,
    )),
    ("audio", re.compile(
        r"Audio|NetEq|AAudio|audio device|capture.?signal|mixing|remix|speech|Opus|ADM\b",
        re.I,
    )),
    ("video_codecs", re.compile(
        r"Video|codec|AV1|simulcast|EncodedImage|FrameSelector|corruption|"
        r"scalability|refresh frame",
        re.I,
    )),
    ("api_sdk", re.compile(r"^sdk:|objc|ObjC|framework|injectable|Environment&", re.I)),
    ("tests", re.compile(r"test|unittest|deflake|mock|xctest|benchmark", re.I)),
    ("build", re.compile(
        r"BUILD\.gn|deps|gn_check|Siso|Reclient|clang-tidy|include cleaner|bot config|\.gni",
        re.I,
    )),
    ("cleanup", re.compile(r"Remove |Delete |Deprecat|Cleanup|clean up|refactor|Migrate|IWYU", re.I)),
)

_MIGRATION_SKIP_HIGHLIGHT_KEYS = frozenset({"rolls_versioning", "reverts_relands"})

_MIGRATION_HIGHLIGHT_SECTIONS: tuple[tuple[str, str], ...] = (
    ("audio", "Audio"),
    ("video_codecs", "Video and Codecs"),
    ("desktop_capture", "Desktop Capture"),
    ("peerconnection_sdp", "PeerConnection and SDP"),
    ("transport", "Transport and Networking"),
    ("stats_metrics", "Stats and Metrics"),
    ("security", "Security and Robustness"),
    ("api_sdk", "API and SDK"),
    ("tests", "Tests and Reliability"),
    ("build", "Build and Infrastructure"),
    ("cleanup", "Cleanup and Modernization"),
    ("general", "General"),
)

_HIGHLIGHT_NOISE_RE = re.compile(
    r"^IWYU|^Roll |^Update WebRTC code version|^Revert ",
    re.I,
)

_INTEGRATION_AREA_RULES: tuple[tuple[str, re.Pattern[str]], ...] = (
    (
        "ObjC SDK and Apple Frameworks",
        re.compile(r"sdk/objc/|PrivacyInfo\.xcprivacy", re.I),
    ),
    (
        "Frame Crypto",
        re.compile(r"frame_crypto|FrameCryptor|DataPacketCryptor", re.I),
    ),
    (
        "Audio Device",
        re.compile(r"audio_device|audio_state|audio_device_module", re.I),
    ),
    (
        "Desktop Capture",
        re.compile(r"desktop_capture|DesktopCapturer|DesktopMedia", re.I),
    ),
    ("Tests", re.compile(r"unittests?/|_tests?\.(cc|mm)", re.I)),
    ("CI and Workflows", re.compile(r"\.github/", re.I)),
    (
        "Build Configuration",
        re.compile(r"BUILD\.gn|webrtc\.gni|build_overrides/", re.I),
    ),
)


def _ref_milestone_label(ref: str) -> str | None:
    m = re.search(r"\bm(\d+)\b", ref, re.I)
    return f"M{m.group(1)}" if m else None


def _classify_migration_subject(subject: str) -> str:
    for key, pattern in _MIGRATION_CATEGORY_RULES:
        if pattern.search(subject):
            return key
    return "general"


def _migration_category_counts(subjects: list[str]) -> dict[str, int]:
    counts: dict[str, int] = {key: 0 for _, key in _MIGRATION_CATEGORY_ROWS}
    for subject in subjects:
        counts[_classify_migration_subject(subject)] += 1
    return counts


def _group_subjects_by_category(subjects: list[str]) -> dict[str, list[str]]:
    grouped: dict[str, list[str]] = {key: [] for _, key in _MIGRATION_CATEGORY_ROWS}
    for subject in subjects:
        grouped[_classify_migration_subject(subject)].append(subject)
    return grouped


def _highlight_subject_score(subject: str) -> int:
    if _HIGHLIGHT_NOISE_RE.match(subject):
        return -10
    score = 0
    if re.match(r"^(Add|Implement|Fix|Improve|Refactor|Expand|Support|Move|Honor|Allow)", subject, re.I):
        score += 3
    if re.search(r"\b(crash|deflake|munging|metric|thread.?safe)\b", subject, re.I):
        score += 2
    if len(subject) > 120:
        score -= 1
    return score


def _format_highlight_subject(subject: str) -> str:
    text = subject.strip().rstrip(".")
    if not text:
        return text
    return text[0].upper() + text[1:]


def _pick_highlight_subjects(subjects: list[str], limit: int = 6) -> list[str]:
    ranked = sorted(
        (s for s in subjects if _highlight_subject_score(s) >= 0),
        key=_highlight_subject_score,
        reverse=True,
    )
    picked: list[str] = []
    seen_prefixes: set[str] = set()
    for subject in ranked:
        prefix = subject.lower()[:48]
        if prefix in seen_prefixes:
            continue
        seen_prefixes.add(prefix)
        picked.append(_format_highlight_subject(subject))
        if len(picked) >= limit:
            break
    return picked


def _category_activity_summary(subjects: list[str]) -> str:
    verbs = ("add", "remove", "fix", "refactor", "update", "implement", "cleanup")
    counts: list[str] = []
    for verb in verbs:
        n = sum(1 for s in subjects if s.lower().startswith(f"{verb} "))
        if n:
            counts.append(f"{n} {verb}")
    return ", ".join(counts) if counts else "mixed functional changes"


def _migration_summary_lines(
    category_counts: dict[str, int],
    grouped: dict[str, list[str]],
) -> list[str]:
    functional = [
        (label, key, category_counts[key])
        for label, key in _MIGRATION_CATEGORY_ROWS
        if key not in _MIGRATION_SKIP_HIGHLIGHT_KEYS and category_counts[key] > 0
    ]
    functional.sort(key=lambda row: -row[2])
    lines: list[str] = []
    for label, key, count in functional[:8]:
        samples = _pick_highlight_subjects(grouped[key], limit=2)
        if samples:
            detail = f" Examples: {'; '.join(samples)}."
        else:
            detail = ""
        lines.append(
            f"- **{label}** ({count:,} commits): {_category_activity_summary(grouped[key])}.{detail}"
        )
    rolls = category_counts.get("rolls_versioning", 0)
    reverts = category_counts.get("reverts_relands", 0)
    if rolls or reverts:
        lines.append(
            f"- **Depot maintenance**: {rolls:,} Chromium rolls/version bumps and "
            f"{reverts:,} reverts/relends."
        )
    return lines


def _append_upstream_highlights(
    lines: list[str],
    grouped: dict[str, list[str]],
    *,
    max_bullets: int = 6,
    min_commits: int = 3,
) -> None:
    for key, heading in _MIGRATION_HIGHLIGHT_SECTIONS:
        if key in _MIGRATION_SKIP_HIGHLIGHT_KEYS:
            continue
        subjects = grouped[key]
        if len(subjects) < min_commits:
            continue
        bullets = _pick_highlight_subjects(subjects, limit=max_bullets)
        if not bullets:
            continue
        lines.extend(["", f"### {heading}", ""])
        lines.append(
            f"_{len(subjects):,} commits ({_category_activity_summary(subjects)})._"
        )
        lines.append("")
        for bullet in bullets:
            lines.append(f"- {bullet}")
        remaining = len(subjects) - len(bullets)
        if remaining > 0:
            lines.append(f"- _…and {remaining:,} additional commits in this area._")


def _list_changed_paths(cwd: Path, range_spec: str) -> list[str]:
    raw = _run_git(["diff", "--name-only", range_spec], cwd)
    return [line.strip() for line in raw.splitlines() if line.strip()]


def _group_paths_by_area(paths: list[str]) -> dict[str, list[str]]:
    grouped: dict[str, list[str]] = {}
    other: list[str] = []
    for path in paths:
        norm = path.replace("\\", "/")
        matched = False
        for area, pattern in _INTEGRATION_AREA_RULES:
            if pattern.search(norm):
                grouped.setdefault(area, []).append(norm)
                matched = True
                break
        if not matched:
            other.append(norm)
    if other:
        grouped["Other"] = other
    return grouped


def _summarize_release_commit(c: Commit) -> list[str]:
    lines = [f"- `{c.short}` {c.subject}"]
    if c.files:
        area_names = ", ".join(sorted(_group_paths_by_area(list(c.files))))
        lines.append(f"  - Touches {len(c.files)} paths across: {area_names}.")
    return lines


def _append_stream_integration(
    lines: list[str],
    cwd: Path,
    integration_range: str,
    integration_commits: list[Commit],
) -> None:
    paths = _list_changed_paths(cwd, integration_range)
    if not paths and not integration_commits:
        return
    lines.extend(["", "## Stream Integration Highlights", ""])
    if integration_commits:
        for c in integration_commits:
            if _UPGRADE_WEBRTC_RE.search(c.subject):
                lines.append(f"- {_format_line(c).lstrip('- ')}")
                break
    by_area = _group_paths_by_area(paths)
    for area, area_paths in sorted(by_area.items()):
        lines.extend(["", f"### {area}", ""])
        for path in area_paths[:12]:
            lines.append(f"- `{path}`")
        if len(area_paths) > 12:
            lines.append(f"- _…and {len(area_paths) - 12} more paths._")


def _list_subjects_in_range(cwd: Path, range_spec: str) -> list[str]:
    raw = _run_git(
        ["log", "--reverse", "--pretty=format:%s", range_spec],
        cwd,
    )
    return [line.strip() for line in raw.splitlines() if line.strip()]


def _count_authors(cwd: Path, range_spec: str) -> int:
    raw = _run_git(["shortlog", "-sn", range_spec], cwd)
    return len([line for line in raw.splitlines() if line.strip()])


def _diff_file_count(cwd: Path, range_spec: str) -> int:
    raw = _run_git(["diff", "--name-only", range_spec], cwd)
    return len([line for line in raw.splitlines() if line.strip()])


def _github_compare_url(repo: str, base: str, head: str) -> str:
    return f"https://github.com/{repo}/compare/{base}...{head}"


def _googlesource_log_url(start: str, end: str) -> str:
    return f"https://webrtc.googlesource.com/src/+log/{start[:12]}..{end[:12]}"


def _write_migration_changelog(
    out: Path,
    *,
    title: str,
    source_branch: str,
    dest_branch: str,
    upstream_from_ref: str,
    upstream_to_ref: str,
    integration_range: str,
    github_repo: str,
    cwd: Path,
    extra_commits: list[Commit] | None = None,
    release_range: str | None = None,
) -> None:
    upstream_from = _resolve_ref(cwd, upstream_from_ref)
    upstream_to = _resolve_ref(cwd, upstream_to_ref)
    upstream_range = f"{upstream_from}..{upstream_to}"
    subjects = _list_subjects_in_range(cwd, upstream_range)
    grouped = _group_subjects_by_category(subjects)
    commit_total = len(subjects)
    author_total = _count_authors(cwd, upstream_range)
    category_counts = _migration_category_counts(subjects)
    integration_files = _diff_file_count(cwd, integration_range)
    integration_commits = _list_commits(cwd, integration_range, first_parent=True)

    release_commits = extra_commits or []
    release_file_count = (
        _diff_file_count(cwd, release_range) if release_range else 0
    )

    from_label = _ref_milestone_label(upstream_from_ref) or upstream_from[:12]
    to_label = _ref_milestone_label(upstream_to_ref) or upstream_to[:12]
    baseline_phrase = (
        f"{from_label} to {to_label}"
        if from_label and to_label and from_label != to_label
        else f"{upstream_from_ref}..{upstream_to_ref}"
    )

    lines: list[str] = [
        f"# {title}",
        "",
        f"Source branch: `{source_branch}`",
        f"Destination branch: `{dest_branch}`",
        "",
        f"[Official WebRTC {baseline_phrase} changes]"
        f"({_googlesource_log_url(upstream_from, upstream_to)})",
        f"[Stream migration comparison]({_github_compare_url(github_repo, dest_branch, source_branch)})",
        "",
        f"This migration updates the Stream WebRTC fork across upstream baseline "
        f"`{upstream_from_ref}..{upstream_to_ref}`.",
        "",
        f"The upstream WebRTC baseline update contains **{commit_total:,} commits by "
        f"{author_total} authors**. The Stream integration range resolves merge conflicts and "
        "preserves Stream-specific SDK, media, crypto, build, and CI changes on top of that "
        "baseline.",
        "",
        "## Summary",
        "",
    ]
    lines.extend(_migration_summary_lines(category_counts, grouped))

    lines.extend(
        [
            "",
            "## Categories",
            "",
            "| Category | Changes |",
            "| --- | ---: |",
        ]
    )
    for label, key in _MIGRATION_CATEGORY_ROWS:
        lines.append(f"| {label} | {category_counts[key]:,} |")
    lines.extend(
        [
            "",
            f"Category counts are based on upstream commit subjects in "
            f"`{upstream_from_ref}..{upstream_to_ref}`; routine Chromium rolls and version "
            "updates are counted separately so they do not obscure functional changes.",
            "",
            "## Upstream WebRTC Highlights",
        ]
    )

    _append_upstream_highlights(lines, grouped)

    _append_stream_integration(lines, cwd, integration_range, integration_commits)

    if release_commits:
        lines.extend(
            [
                "",
                f"## Additional changes in `{source_branch}` (outside baseline upgrade)",
                "",
            ]
        )
        for c in release_commits:
            lines.extend(_summarize_release_commit(c))

    integration_areas = ", ".join(sorted(_group_paths_by_area(_list_changed_paths(cwd, integration_range))))
    lines.extend(
        [
            "",
            "## Notes for Reviewers",
            "",
            f"- The upstream baseline range used for release-note synthesis is "
            f"`{upstream_from_ref}..{upstream_to_ref}`.",
            f"- The Stream integration diff (`{integration_range}`) is **{integration_files} "
            f"files changed**"
            + (f" ({integration_areas})." if integration_areas else ".")
        ]
    )
    if release_commits and release_file_count:
        lines.append(
            f"- The full `{source_branch}` → `{dest_branch}` release delta is **{release_file_count} "
            f"files changed** across {len(release_commits)} fork commit(s) on top of the baseline upgrade."
        )
    lines.extend(
        [
            "- Upstream highlights are sampled from commit subjects (noise such as rolls/IWYU "
            "filtered); treat category counts as guidance, not exact ownership.",
            "- Before publishing, validate against platform builds, unit tests, and manual QA for "
            "areas touched in the integration diff and release commits.",
            "",
        ]
    )
    out.write_text("\n".join(lines), encoding="utf-8")


def _write_changelog(
    out: Path,
    title_from: str,
    title_to: str,
    commits: list[Commit],
    *,
    range_note: str,
    expand_upstream: bool = False,
    repo: Path | None = None,
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
            if expand_upstream and _should_expand_upstream(c):
                lines.append(
                    "  - _Expanded upstream breakdown in "
                    "[Upstream WebRTC merge](#upstream-webrtc-merge)._"
                )
    else:
        lines.append("_None auto-flagged._")
    lines.extend(
        [
            "",
            "## Upstream WebRTC merge {#upstream-webrtc-merge}",
            "",
        ]
    )
    expand_targets = [c for c in commits if _should_expand_upstream(c)]
    expanded_hashes: set[str] = set()

    if expand_upstream and repo is not None and expand_targets:
        for c in expand_targets:
            subjects, source_note = _expand_upstream_subjects(repo, c)
            if subjects:
                expanded_hashes.add(c.hash)
                _format_upstream_groups(
                    lines,
                    c,
                    _group_upstream_subjects(subjects),
                    source_note=source_note,
                )
            else:
                lines.append(_format_line(c))
    if sections["upstream"]:
        for c in sections["upstream"]:
            if c.hash in expanded_hashes:
                continue
            lines.append(_format_line(c))
    elif not expand_targets or not expanded_hashes:
        if not (expand_upstream and expand_targets):
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
    parser.add_argument(
        "--expand-upstream",
        action="store_true",
        help=(
            "Expand large/upstream commits: use merge parents when available, "
            "otherwise GitHub PR commits (requires gh), grouped by feature area."
        ),
    )
    parser.add_argument(
        "--format",
        choices=("draft", "migration"),
        default="draft",
        help="Output style: categorized draft (default) or full migration release notes.",
    )
    parser.add_argument(
        "--title",
        default=None,
        help="Title for --format migration (default: derived from upstream milestone refs).",
    )
    parser.add_argument(
        "--source-branch",
        default="iliaspavlidakis/merge-webrtc-m145",
        help="Source branch label for migration compare links.",
    )
    parser.add_argument(
        "--dest-branch",
        default="develop",
        help="Destination branch label for migration compare links.",
    )
    parser.add_argument(
        "--upstream-from",
        default="webrtc/m137",
        help="Upstream baseline start ref for migration notes.",
    )
    parser.add_argument(
        "--upstream-to",
        default=None,
        help="Upstream baseline end ref for migration notes (required for --format migration).",
    )
    parser.add_argument(
        "--integration-range",
        default=None,
        help=(
            "Git range for Stream-only integration diff (e.g. main..98d147a56bdd). "
            "Defaults to --from..--to when --format migration is used with --from/--to."
        ),
    )
    parser.add_argument(
        "--github-repo",
        default="GetStream/webrtc",
        help="GitHub org/repo for compare links.",
    )
    args = parser.parse_args()

    cwd = args.repo or Path(__file__).resolve().parent.parent

    if args.format == "migration":
        if not args.from_ref:
            parser.error("--from is required for --format migration")
        if not args.upstream_to:
            parser.error("--upstream-to is required for --format migration")
        from_full = _resolve_ref(cwd, args.from_ref)
        to_full = _resolve_ref(cwd, args.to_ref)
        integration_range = args.integration_range or f"{from_full}..{to_full}"
        release_commits = _list_commits(cwd, f"{from_full}..{to_full}", first_parent=True)
        extra = [
            c
            for c in release_commits
            if not _UPGRADE_WEBRTC_RE.search(c.subject)
        ]
        upstream_to_full = _resolve_ref(cwd, args.upstream_to)
        from_label = _ref_milestone_label(args.upstream_from) or args.upstream_from
        to_label = _ref_milestone_label(args.upstream_to) or upstream_to_full[:12]
        title = args.title or f"WebRTC Changelog {from_label}..{to_label} Migration"
        _write_migration_changelog(
            args.output,
            title=title,
            source_branch=args.source_branch,
            dest_branch=args.dest_branch,
            upstream_from_ref=args.upstream_from,
            upstream_to_ref=args.upstream_to,
            integration_range=integration_range,
            github_repo=args.github_repo,
            cwd=cwd,
            extra_commits=extra or None,
            release_range=f"{from_full}..{to_full}",
        )
        print(f"Wrote migration changelog to {args.output}", file=sys.stderr)
        return

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
        expand_upstream=args.expand_upstream,
        repo=cwd,
    )
    print(f"Wrote {len(commits)} commits to {args.output}", file=sys.stderr)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Select the Chromium stable WebRTC milestone and the next fork target.

The purple row on https://chromiumdash.appspot.com/branches is the milestone
whose schedule_phase is "stable". stable_cut and extended are other rows.
"""

import json
import sys
import urllib.error
import urllib.request

MILESTONES_URL = "https://chromiumdash.appspot.com/fetch_milestones?num=80"
RELEASES_URL = (
    "https://chromiumdash.appspot.com/fetch_releases?channel=Stable&platform=Mac&num=1"
)
LOG_URL = "https://webrtc.googlesource.com/src.git/+log/refs/branch-heads/{branch}"


def log_url(branch):
    return LOG_URL.format(branch=branch)


def row_view(row):
    milestone = int(row["milestone"])
    branch = str(row["webrtc_branch"])
    return {
        "milestone": milestone,
        "version": "M{0}".format(milestone),
        "webrtc_branch": branch,
        "ref": "refs/branch-heads/{0}".format(branch),
        "log_url": log_url(branch),
    }


def pick_stable(milestones):
    rows = [row for row in milestones if row.get("schedule_phase") == "stable"]
    if not rows:
        raise SystemExit("No milestone has schedule_phase stable.")
    rows.sort(key=lambda row: int(row["milestone"]))
    if any(not row.get("webrtc_branch") for row in rows):
        raise SystemExit("The stable row has no webrtc_branch.")
    return rows[-1]


def rejected_rows(milestones, stable_milestone):
    """Channel rows that are not the purple stable target.

    Older milestones can keep a stale phase such as extended.
    Omit those rows here. The merge target is the stable row.
    """
    rejected = []
    for row in milestones:
        phase = row.get("schedule_phase")
        number = int(row["milestone"])
        if not phase or phase == "stable":
            continue
        if number >= stable_milestone or number == stable_milestone - 1:
            rejected.append({"milestone": number, "schedule_phase": phase})
    rejected.sort(key=lambda row: row["milestone"], reverse=True)
    return rejected


def next_target(milestones, current, stable_milestone):
    """Return the stable row when the fork is behind stable."""
    if current > stable_milestone:
        raise SystemExit(
            "Current milestone M{0} is above stable M{1}.".format(
                current, stable_milestone
            )
        )
    if current == stable_milestone:
        return None
    for row in milestones:
        if int(row["milestone"]) == stable_milestone:
            if not row.get("webrtc_branch"):
                raise SystemExit("The stable row has no webrtc_branch.")
            return row
    raise SystemExit(
        "Stable milestone {0} is not in the milestones feed.".format(stable_milestone)
    )


def fetch_json(url):
    request = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def build_report(milestones, current, releases):
    stable = pick_stable(milestones)
    stable_milestone = int(stable["milestone"])
    report = {
        "stable": row_view(stable),
        "rejected": rejected_rows(milestones, stable_milestone),
        "already_on_stable": False,
    }
    if isinstance(releases, list) and releases:
        report["chrome_stable"] = {
            "milestone": int(releases[0]["milestone"]),
            "version": releases[0].get("version"),
            "webrtc_hash": (releases[0].get("hashes") or {}).get("webrtc"),
        }
        report["same_milestone_as_chrome"] = (
            report["chrome_stable"]["milestone"] == stable_milestone
        )
    if current is None:
        return report
    report["current"] = {"milestone": current, "version": "M{0}".format(current)}
    for row in milestones:
        if int(row["milestone"]) == current and row.get("webrtc_branch"):
            report["current"] = row_view(row)
            break
    target = next_target(milestones, current, stable_milestone)
    if target is None:
        report["already_on_stable"] = True
        report["next"] = None
        return report
    report["next"] = row_view(target)
    return report


FIXTURE = [
    {"milestone": 158, "webrtc_branch": "8127", "schedule_phase": "stable_cut"},
    {"milestone": 157, "webrtc_branch": "8103", "schedule_phase": "stable"},
    {"milestone": 156, "webrtc_branch": "8078", "schedule_phase": "extended"},
    {"milestone": 150, "webrtc_branch": "7003", "schedule_phase": "extended"},
    {"milestone": 149, "webrtc_branch": "7002"},
    {"milestone": 148, "webrtc_branch": "7778"},
]


def selftest():
    stable = pick_stable(FIXTURE)
    assert int(stable["milestone"]) == 157, stable
    assert str(stable["webrtc_branch"]) == "8103"
    assert int(next_target(FIXTURE, 145, 157)["milestone"]) == 157
    assert next_target(FIXTURE, 148, 157)["webrtc_branch"] == "8103"
    assert next_target(FIXTURE, 150, 157)["webrtc_branch"] == "8103"
    assert next_target(FIXTURE, 157, 157) is None
    rejected = rejected_rows(FIXTURE, 157)
    phases = {row["schedule_phase"] for row in rejected}
    assert phases == {"stable_cut", "extended"}, phases
    assert all(row["milestone"] != 150 for row in rejected)
    report = build_report(FIXTURE, 148, None)
    assert report["next"]["version"] == "M157"
    assert report["next"]["log_url"].endswith("/8103")
    try:
        next_target([{"milestone": 148, "webrtc_branch": "7778"}], 148, 157)
    except SystemExit as error:
        assert "157" in str(error), error
    else:
        raise SystemExit("A missing stable row must fail.")
    print("discover_stable selftest passed")


def parse_current(argv):
    if "--current" not in argv:
        return None
    index = argv.index("--current")
    if index + 1 >= len(argv):
        raise SystemExit("Pass an integer after --current.")
    try:
        return int(argv[index + 1])
    except ValueError:
        raise SystemExit("--current must be an integer milestone.")


def main(argv):
    if "--selftest" in argv:
        selftest()
        return 0
    current = parse_current(argv)
    try:
        milestones = fetch_json(MILESTONES_URL)
    except urllib.error.URLError as error:
        raise SystemExit("Milestones feed failed: {0}".format(error))
    try:
        releases = fetch_json(RELEASES_URL)
    except urllib.error.URLError as error:
        releases = None
        sys.stderr.write("Chrome releases feed failed: {0}\n".format(error))
    report = build_report(milestones, current, releases)
    json.dump(report, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

#!/usr/bin/env python3
"""Select the Chromium extended stable WebRTC milestone and the next fork target.

The extended stable row on https://chromiumdash.appspot.com/branches is the
highest milestone whose schedule_phase is "extended". stable and stable_cut
are other rows. Older milestones can keep a stale extended phase.
"""

import json
import sys
import urllib.error
import urllib.request

MILESTONES_URL = "https://chromiumdash.appspot.com/fetch_milestones?num=80"
RELEASES_URL = (
    "https://chromiumdash.appspot.com/fetch_releases?channel=Extended&platform=Mac&num=1"
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


def pick_extended_stable(milestones):
    rows = [row for row in milestones if row.get("schedule_phase") == "extended"]
    if not rows:
        raise SystemExit("No milestone has schedule_phase extended.")
    rows.sort(key=lambda row: int(row["milestone"]))
    if any(not row.get("webrtc_branch") for row in rows):
        raise SystemExit("The extended stable row has no webrtc_branch.")
    return rows[-1]


def rejected_rows(milestones, extended_milestone):
    """Channel rows that are not the extended stable target.

    Older milestones can keep a stale extended phase.
    Omit those rows here. The merge target is the extended stable row.
    """
    rejected = []
    for row in milestones:
        phase = row.get("schedule_phase")
        number = int(row["milestone"])
        if not phase or phase == "extended":
            continue
        if number >= extended_milestone or number == extended_milestone - 1:
            rejected.append({"milestone": number, "schedule_phase": phase})
    rejected.sort(key=lambda row: row["milestone"], reverse=True)
    return rejected


def next_target(milestones, current, extended_milestone):
    """Return the extended stable row when the fork is behind it."""
    if current > extended_milestone:
        raise SystemExit(
            "Current milestone M{0} is above extended stable M{1}.".format(
                current, extended_milestone
            )
        )
    if current == extended_milestone:
        return None
    for row in milestones:
        if int(row["milestone"]) == extended_milestone:
            if not row.get("webrtc_branch"):
                raise SystemExit("The extended stable row has no webrtc_branch.")
            return row
    raise SystemExit(
        "Extended stable milestone {0} is not in the milestones feed.".format(
            extended_milestone
        )
    )


def fetch_json(url):
    request = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def build_report(milestones, current, releases):
    extended = pick_extended_stable(milestones)
    extended_milestone = int(extended["milestone"])
    report = {
        "extended_stable": row_view(extended),
        "rejected": rejected_rows(milestones, extended_milestone),
        "already_on_extended_stable": False,
    }
    if isinstance(releases, list) and releases:
        report["chrome_extended"] = {
            "milestone": int(releases[0]["milestone"]),
            "version": releases[0].get("version"),
            "webrtc_hash": (releases[0].get("hashes") or {}).get("webrtc"),
        }
        report["same_milestone_as_chrome"] = (
            report["chrome_extended"]["milestone"] == extended_milestone
        )
    if current is None:
        return report
    report["current"] = {"milestone": current, "version": "M{0}".format(current)}
    for row in milestones:
        if int(row["milestone"]) == current and row.get("webrtc_branch"):
            report["current"] = row_view(row)
            break
    target = next_target(milestones, current, extended_milestone)
    if target is None:
        report["already_on_extended_stable"] = True
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
    extended = pick_extended_stable(FIXTURE)
    assert int(extended["milestone"]) == 156, extended
    assert str(extended["webrtc_branch"]) == "8078"
    assert int(next_target(FIXTURE, 145, 156)["milestone"]) == 156
    assert next_target(FIXTURE, 148, 156)["webrtc_branch"] == "8078"
    assert next_target(FIXTURE, 150, 156)["webrtc_branch"] == "8078"
    assert next_target(FIXTURE, 156, 156) is None
    try:
        next_target(FIXTURE, 157, 156)
    except SystemExit as error:
        assert "above extended stable" in str(error), error
    else:
        raise SystemExit("A fork above extended stable must fail.")
    rejected = rejected_rows(FIXTURE, 156)
    phases = {row["schedule_phase"] for row in rejected}
    assert phases == {"stable_cut", "stable"}, phases
    assert all(row["milestone"] != 150 for row in rejected)
    report = build_report(
        FIXTURE,
        148,
        [{"milestone": 156, "version": "156.0.8078.80", "hashes": {"webrtc": "abc"}}],
    )
    assert report["extended_stable"]["milestone"] == 156
    assert report["next"]["version"] == "M156"
    assert report["next"]["log_url"].endswith("/8078")
    assert report["chrome_extended"]["milestone"] == 156
    assert report["same_milestone_as_chrome"] is True
    assert report["already_on_extended_stable"] is False
    done = build_report(FIXTURE, 156, None)
    assert done["already_on_extended_stable"] is True
    assert done["next"] is None
    try:
        next_target([{"milestone": 148, "webrtc_branch": "7778"}], 148, 156)
    except SystemExit as error:
        assert "156" in str(error), error
    else:
        raise SystemExit("A missing extended stable row must fail.")
    try:
        pick_extended_stable(
            [{"milestone": 157, "webrtc_branch": "8103", "schedule_phase": "stable"}]
        )
    except SystemExit as error:
        assert "extended" in str(error), error
    else:
        raise SystemExit("A missing extended phase must fail.")
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

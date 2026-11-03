#!/usr/bin/env python3
"""Decide whether to migrate, and check the merge before it is pushed.

`make migrate-plan` and `make migrate-open` call this. The milestone feed
stays in agents/skills/migrate/scripts/discover_stable.py.
"""

import argparse
import json
import re
import sys

MILESTONE_RE = re.compile(
    r"(?:Upgrade to m|Merge WebRTC M|Migrate to version M)(\d+)\b"
)
REF_RE = re.compile(r"refs/branch-heads/\d+\Z")


def read_lines(path):
    with open(path, "r") as handle:
        return [line.strip() for line in handle if line.strip()]


def read_integers(path):
    numbers = []
    for line in read_lines(path):
        if not line.isdigit():
            raise SystemExit("Expected an integer milestone, got {0}.".format(line))
        numbers.append(int(line))
    return numbers


def milestone_numbers(subject):
    return [int(match) for match in MILESTONE_RE.findall(subject)]


def current_milestone(ancestors, subjects):
    """Highest milestone already represented on the fork."""
    numbers = list(ancestors)
    for subject in subjects:
        numbers.extend(milestone_numbers(subject))
    if not numbers:
        return None
    return max(numbers)


def load_json(path):
    with open(path, "r") as handle:
        return json.load(handle)


def plan(discovery, open_heads, merged_heads, force):
    """Return the gate decision for one extended stable target.

    force skips the open-PR and merged-PR checks. It does not migrate when
    the fork is already on extended stable.
    """
    extended = discovery.get("extended_stable") or {}
    target = discovery.get("next") or {}
    milestone = target.get("milestone", extended.get("milestone"))
    if milestone is not None:
        milestone = int(milestone)
    ref = target.get("ref") or extended.get("ref") or ""
    upgrade = "merge-webrtc-m{0}".format(milestone) if milestone else ""
    baseline = "webrtc/m{0}".format(milestone) if milestone else ""
    version = target.get("version") or (
        "M{0}".format(milestone) if milestone else ""
    )
    if discovery.get("already_on_extended_stable") or not discovery.get("next"):
        if discovery.get("already_on_extended_stable"):
            reason = "The fork is already on extended stable."
        else:
            reason = "The milestones feed has no extended stable target."
        return decision(False, reason, milestone, ref, "", "")
    if not REF_RE.match(ref):
        raise SystemExit("Refusing unexpected official ref {0}.".format(ref))
    if not force and upgrade in open_heads:
        return decision(
            False,
            "An open pull request already uses {0}.".format(upgrade),
            milestone,
            ref,
            upgrade,
            baseline,
        )
    if not force and upgrade in merged_heads:
        return decision(
            False,
            "A merged pull request already used {0}.".format(upgrade),
            milestone,
            ref,
            upgrade,
            baseline,
        )
    return decision(
        True,
        "Extended stable {0} is not on the fork.".format(version),
        milestone,
        ref,
        upgrade,
        baseline,
    )


def decision(should_run, reason, milestone, ref, upgrade, baseline):
    return {
        "should_run": should_run,
        "reason": reason,
        "milestone": milestone if milestone is not None else "",
        "ref": ref,
        "upgrade_branch": upgrade,
        "baseline_branch": baseline,
    }


def check_merge(
    fork_sha, official_sha, baseline_sha, head_parents, first_parent_count, repair_parents
):
    """Return errors for an upgrade commit that must not be pushed.

    A clean merge has one first-parent commit: the fork tip merged with the
    official tip. Ancestry repair adds one earlier ours-merge of the fork tip.
    """
    errors = []
    if baseline_sha != official_sha:
        errors.append("Baseline branch does not match the official tip.")
    if len(head_parents) != 2:
        errors.append("Upgrade HEAD must be a two-parent merge.")
        return errors
    if head_parents[1] != official_sha:
        errors.append("The merge's second parent is not the official tip.")
    if first_parent_count == 1:
        if head_parents[0] != fork_sha:
            errors.append("The merge's first parent is not the fork tip.")
        if repair_parents:
            errors.append("A one-commit first-parent history cannot include an ancestry repair.")
    elif first_parent_count == 2:
        if head_parents[0] == fork_sha:
            errors.append("The ancestry repair is missing from the first-parent history.")
        if len(repair_parents) != 2:
            errors.append("The ancestry repair must be a two-parent merge.")
        elif repair_parents[0] != fork_sha:
            errors.append("The ancestry repair must start from the fork tip.")
    else:
        errors.append(
            "First-parent history has {0} commits after the fork tip. Expected 1 or 2.".format(
                first_parent_count
            )
        )
    return errors


def write_github_output(path, values):
    with open(path, "a") as handle:
        for key, value in values.items():
            if isinstance(value, bool):
                text = "true" if value else "false"
            elif value is None:
                text = ""
            else:
                text = str(value)
            if "\n" in text:
                raise SystemExit("Output {0} contains a newline.".format(key))
            handle.write("{0}={1}\n".format(key, text))


def cmd_current(args):
    found = current_milestone(
        read_integers(args.ancestors_file), read_lines(args.subjects_file)
    )
    if found is None:
        raise SystemExit("No milestone is on the fork.")
    print(found)
    return 0


def cmd_decide(args):
    result = plan(
        load_json(args.discovery),
        set(read_lines(args.open_heads)),
        set(read_lines(args.merged_heads)),
        args.force,
    )
    if args.github_output:
        write_github_output(args.github_output, result)
    json.dump(result, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


def cmd_check_merge(args):
    errors = check_merge(
        args.fork_sha,
        args.official_sha,
        args.baseline_sha,
        args.head_parent,
        args.first_parent_count,
        args.repair_parent,
    )
    if errors:
        for error in errors:
            sys.stderr.write("{0}\n".format(error))
        return 1
    print("merge check passed")
    return 0


def selftest():
    assert current_milestone([125, 104], ["Upgrade to m145 (#91)"]) == 145
    assert milestone_numbers("Upgrade to m145 (#91)") == [145]
    assert milestone_numbers(
        "Merge WebRTC M156 (branch-head 8078) into main"
    ) == [156]
    assert milestone_numbers(
        "[Automated]Migrate to version M156 19576e37870bfe5a0a910a32f98ff411f722f43a"
    ) == [156]
    assert current_milestone([], []) is None

    discovery = {
        "already_on_extended_stable": False,
        "extended_stable": {"milestone": 156, "ref": "refs/branch-heads/8078"},
        "next": {
            "milestone": 156,
            "ref": "refs/branch-heads/8078",
            "version": "M156",
        },
    }
    run = plan(discovery, set(), set(), False)
    assert run["should_run"] is True
    assert run["upgrade_branch"] == "merge-webrtc-m156"
    assert run["baseline_branch"] == "webrtc/m156"
    blocked = plan(discovery, {"merge-webrtc-m156"}, set(), False)
    assert blocked["should_run"] is False
    assert "open pull request" in blocked["reason"]
    other = plan(discovery, {"merge-webrtc-m145", "merge-webrtc-m1560"}, set(), False)
    assert other["should_run"] is True
    merged = plan(discovery, set(), {"merge-webrtc-m156"}, False)
    assert merged["should_run"] is False
    forced = plan(discovery, {"merge-webrtc-m156"}, {"merge-webrtc-m156"}, True)
    assert forced["should_run"] is True
    done = plan(
        {
            "already_on_extended_stable": True,
            "next": None,
            "extended_stable": {"milestone": 156, "ref": "refs/branch-heads/8078"},
        },
        set(),
        set(),
        True,
    )
    assert done["should_run"] is False
    assert done["upgrade_branch"] == ""
    missing = plan({"already_on_extended_stable": False, "next": None}, set(), set(), True)
    assert missing["should_run"] is False
    try:
        plan(
            {
                "already_on_extended_stable": False,
                "next": {"milestone": 156, "ref": "refs/heads/main", "version": "M156"},
            },
            set(),
            set(),
            False,
        )
    except SystemExit as error:
        assert "unexpected official ref" in str(error)
    else:
        raise SystemExit("A non branch-head ref must fail.")

    fork = "a" * 40
    official = "b" * 40
    repair = "c" * 40
    assert check_merge(fork, official, official, [fork, official], 1, []) == []
    assert check_merge(fork, official, official, [repair, official], 2, [fork, "d" * 40]) == []
    assert check_merge(fork, official, "e" * 40, [fork, official], 1, [])
    assert check_merge(fork, official, official, [fork], 1, [])
    assert check_merge(fork, official, official, [fork, "e" * 40], 1, [])
    assert check_merge(fork, official, official, [repair, official], 1, [])
    assert check_merge(fork, official, official, [fork, official], 2, [fork, "d" * 40])
    assert check_merge(fork, official, official, [repair, official], 2, [official])
    assert check_merge(fork, official, official, [repair, official], 2, ["e" * 40, fork])
    assert check_merge(fork, official, official, [fork, official], 3, [])
    print("migration_gate selftest passed")


def build_parser():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command")
    current = sub.add_parser("current")
    current.add_argument("--ancestors-file", required=True)
    current.add_argument("--subjects-file", required=True)
    current.set_defaults(func=cmd_current)
    decide = sub.add_parser("decide")
    decide.add_argument("--discovery", required=True)
    decide.add_argument("--open-heads", required=True)
    decide.add_argument("--merged-heads", required=True)
    decide.add_argument("--force", action="store_true")
    decide.add_argument("--github-output")
    decide.set_defaults(func=cmd_decide)
    check = sub.add_parser("check-merge")
    check.add_argument("--fork-sha", required=True)
    check.add_argument("--official-sha", required=True)
    check.add_argument("--baseline-sha", required=True)
    check.add_argument("--head-parent", action="append", required=True)
    check.add_argument("--first-parent-count", type=int, required=True)
    check.add_argument("--repair-parent", action="append", default=[])
    check.set_defaults(func=cmd_check_merge)
    return parser


def main(argv):
    if "--selftest" in argv:
        selftest()
        return 0
    parser = build_parser()
    args = parser.parse_args(argv)
    if not getattr(args, "func", None):
        parser.print_help(sys.stderr)
        return 2
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

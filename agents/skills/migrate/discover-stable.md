# Discover the stable milestone

Run the selector from the git root.

```bash
python3 agents/skills/migrate/scripts/discover_stable.py --selftest
python3 agents/skills/migrate/scripts/discover_stable.py --current <milestone>
```

The script prints JSON.

Trust `stable` in that JSON.

The purple row is `schedule_phase` `stable`.

Do not select `stable_cut` as the stable target.

Do not select `extended` as the stable target.

`rejected` names those channel rows.

`next` is the stable row.

Do not merge any milestone between the fork and `stable`.

The Chrome releases feed can lag the branches page.

When `same_milestone_as_chrome` is false, keep the purple target.

Record both milestones in the PR.

When that key is absent, record the feed failure.

Keep the purple target.

## Read the fork branch

1. Fetch `origin`.
2. Use `origin/develop` when that ref exists.
3. Otherwise use the remote default branch.
4. Record the choice and the reason in the PR.
5. Do not create `develop` when that ref is absent.

## Read the current milestone

Run this from the fork branch.

```bash
git branch -a --list 'webrtc/m*' 'origin/webrtc/m*'
git log --oneline --grep='Upgrade to m'
git log --merges --oneline --grep='Merge WebRTC M'
```

The current milestone is the highest `M` number that is already in the fork branch.

A baseline ref counts only when it is an ancestor of the fork branch.

```bash
git merge-base --is-ancestor <baseline-ref> <fork-branch>
```

Exit status 0 means the baseline is in the fork.

A squash can leave the baseline ref outside the fork.

Then read the milestone from the squash subject.

Record that the ancestry is missing.

## Stop on an open upgrade

List branches named `merge-webrtc-m*`.

For each branch, run both commands.

```bash
git merge-base --is-ancestor <upgrade-branch> <fork-branch>
git rev-list --left-right --count <fork-branch>...<upgrade-branch>
```

Stop when the upgrade branch is not an ancestor.

Show the branch name and both counts.

Ask which branch is the fork for this run.

Do not drop commits that exist only on the default branch.

Do not start a newer milestone on top of that split.

## Pass the milestone to the script

Pass the current milestone as `--current`.

Use `next` from the JSON as the merge target.

Stop when `already_on_stable` is true.

Stop when the stable row is missing from the feed.

## Official commit

Fetch the next ref after you accept `next`.

```bash
git fetch <official-remote> <next.ref>
git rev-parse FETCH_HEAD
```

The official remote URL contains `webrtc.googlesource.com/src`.

This checkout names that remote `official`.

The full `FETCH_HEAD` hash is the commit in the PR title.

The `log_url` value is the link in the PR body.

Merge that branch tip.

Do not merge the Chrome `webrtc_hash` when it differs.

Record the difference as a risk.

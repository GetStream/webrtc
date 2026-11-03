# Merge the extended stable milestone

Work on a new upgrade branch.

Do not commit on the fork branch.

Do not push the fork branch.

Do not force-push any branch.

## Prepare the baseline

Fetch the official tip.

```bash
git fetch <official-remote> refs/branch-heads/<branch>
git rev-parse FETCH_HEAD
```

Create `webrtc/m<milestone>` when the name is absent.

```bash
git branch webrtc/m<milestone> FETCH_HEAD
```

When the name exists, move it only as a fast-forward.

```bash
git merge-base --is-ancestor webrtc/m<milestone> FETCH_HEAD
git branch -f webrtc/m<milestone> FETCH_HEAD
```

Stop when the ancestor command exits 1.

The baseline branch must stay free of Stream commits.

Push the baseline without force.

```bash
git push origin webrtc/m<milestone>
```

Fetch the fork's current official tip when ancestry is missing.

That tip is the baseline already in the fork, or named by the squash subject.

Do not fetch the milestones between the fork and extended stable.

## Cut the upgrade branch

```bash
git switch <fork-branch>
git pull --ff-only origin <fork-branch>
git switch -c merge-webrtc-m<milestone>
git config rerere.enabled true
git config rerere.autoupdate true
```

Stop when the fast-forward pull fails.

`rerere` is local to this clone.

## Repair missing ancestry

Run this test before the content merge.

```bash
git merge-base --is-ancestor <previous-baseline-sha> HEAD
```

Exit status 0 means the history is intact.

Skip the repair.

Exit status 1 means a past PR used a squash.

Record the previous official tip without a tree change.

```bash
git merge -s ours --no-edit <previous-baseline-sha>
```

Use this repair only for the fork's current official tip.

Do not point `-s ours` at a milestone between the fork and extended stable.

## Merge

```bash
git merge --no-ff webrtc/m<milestone>
```

Count unmerged files.

```bash
git diff --name-only --diff-filter=U
```

Abort the run when the count stays above 100.

```bash
git merge --abort
git switch <fork-branch>
git branch -D merge-webrtc-m<milestone>
```

Do that only before the first push of the upgrade branch.

Then stop and report the count.

A clean merge commits by itself.

Do not add an empty second commit.

When conflicts remain, resolve them with [resolve-conflicts.md](resolve-conflicts.md).

Then commit the merge.

```bash
git commit
```

Use this subject.

```text
Merge WebRTC M<milestone> (branch-head <branch>) into <fork-branch>
```

Put the full official hash in the body.

## Leave the tree mergeable

Do not run a local framework build unless the user asks.

A local build takes hours.

`gclient sync` is also out of scope unless the user asks.

Record `DEPS` changes as a risk when that file differs.

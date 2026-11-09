# Open the PR

Push the upgrade branch after the merge commit exists.

```bash
git push -u origin merge-webrtc-m<milestone>
```

Do not push the fork branch.

Do not merge the PR.

Do not squash.

Do not rebase.

## Title

Use this title with the real values.

No extra words.

```text
[Automated]Migrate to version M<milestone> <full-commit-hash>
```

`M<milestone>` is the version.

The hash is the full official `FETCH_HEAD`.

Example shape:

```text
[Automated]Migrate to version M157 0123456789abcdef0123456789abcdef01234567
```

## Body

Write the body in short sentences.

Use active verbs.

Keep each list to five items.

Put the full file list in one fenced block, not a long bullet list.

Use this outline.

~~~markdown
## Target

Milestone: M157
Official branch: refs/branch-heads/8103
Official commit: <full hash>
Log: https://webrtc.googlesource.com/src.git/+log/refs/branch-heads/8103

The fork branch is `<name>` because `<reason>`.

## Decisions

1. One sentence. Name the path and the choice.

## Conflicts

Unmerged files at the start: <count>
Files changed by the merge: <count>

Highest-risk choices:

1. `<path>`: one sentence for the choice.

Full path list:

```text
one/path/per/line
```

## Risks

1. One risk in one sentence.

## Checks

Local framework build: not run.
make check: <pass or fail>.
check-android-jni.sh: <pass or the reports>.
Chrome extended stable milestone: <milestone or same>.

Land this PR as a merge commit.
Do not squash.
Do not rebase.
~~~

Replace every placeholder.

Omit a decision you did not make.

When a Chrome hash differs from the branch tip, add that risk.

When you used `git merge -s ours`, add that decision.

Include the previous baseline hash.

## Create

```bash
gh pr create --repo GetStream/webrtc --base <fork-branch> --head merge-webrtc-m<milestone> --title "<title>" --body-file <file>
```

Stop when `origin` is not `GetStream/webrtc`.

Print the PR URL.

Then stop.

## After the PR

Do not land the PR in this skill.

The land command is a fast-forward on the fork branch.

Run it only after the user asks.

```bash
git switch <fork-branch>
git pull --ff-only origin <fork-branch>
git merge --ff-only merge-webrtc-m<milestone>
git push origin <fork-branch>
```

Read the parents after the push.

```bash
git log --graph --oneline -5 <fork-branch>
```

The upgrade commit must show two parents.

One parent is the official tip.

The other parent is the previous fork tip.

A squash has one parent.

If that happens, stop.

Do not repair a squash with a force push.

## Before the Maven publish

Tell the user to hold the `maven-publish` approval until these pass.

Green CI does not prove the AAR works. The instrumentation test APK generates its own JNI classes and links its own natives.

1. Download `libwebrtc.aar` from the release.
2. Run `verify-android-jar.sh` on its `classes.jar`.
3. Run `verify-android-natives.sh` on that jar and every `jni/<abi>` library.
4. Smoke-test the dogfooding app: create a `PeerConnectionFactory`, then join one call with E2EE on.

```bash
unzip -o libwebrtc.aar classes.jar 'jni/*' -d aar
stream_build/scripts/verify-android-jar.sh --jar aar/classes.jar
stream_build/scripts/verify-android-natives.sh --jar aar/classes.jar \
  $(printf -- '--so %s ' aar/jni/*/*.so)
```

Stop and report when any step fails.

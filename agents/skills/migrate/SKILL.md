---
name: migrate
description: >-
  Merges the latest stable WebRTC milestone straight into the Stream fork.
  Use when the user asks to migrate or upgrade a WebRTC milestone.
disable-model-invocation: true
---

# Migrate WebRTC

Run this skill from the git root of `GetStream/webrtc`.

That directory is `src` in the gclient checkout.

1. Read [discover-stable.md](discover-stable.md). Select the stable milestone.
2. Read [merge-forward.md](merge-forward.md). Merge that milestone.
3. Read [resolve-conflicts.md](resolve-conflicts.md). Resolve each conflict.
4. Read [pull-request.md](pull-request.md). Open one PR.
5. Stop after you print the PR URL. Do not merge the PR.

Merge the stable milestone in this run.

Stop when the fork is already on that milestone.

## Stop before you merge

Stop and ask one question when any rule below is true.

1. An upgrade branch is not contained in the fork branch.
2. The ahead and behind counts are both above zero.
3. A conflict changes Stream behavior and the keep-rule does not fit.
4. Unmerged files stay above 100 after the ancestry repair.
5. The milestones feed has no `schedule_phase` of `stable`.

## Words

Use these words for the whole run.

- Fork branch: the long-lived Stream branch.
- Baseline branch: `webrtc/m<milestone>`. Official commits only.
- Upgrade branch: `merge-webrtc-m<milestone>`.
- Stable milestone: the purple row on the branches page. This is the only merge target.
- Keep-rule: keep Stream behavior and adopt the new API.

Do not say "patch branch". Stream retired that model.

## Model

Merge the stable milestone straight into the fork branch.

Do not merge any milestone between the fork and stable.

Keep Stream commits in their original place.

Do not replay Stream commits onto a fresh official tree.

Do not squash the upgrade PR.

Do not rebase the upgrade PR.

## User updates

Write each update in short sentences.

Use active verbs.

1. Put the next action on the first line.
2. Number the steps when more than one step remains.
3. End with one action that takes under two minutes.
4. Keep each visible list to five items.
5. Give the estimate in minutes.

Use these estimates unless the conflict count changes them.

- Discovery takes about 2 minutes.
- A merge under 40 conflicts takes about 30 minutes.
- Ancestry repair adds about 15 minutes.
- Each behavior conflict takes about 5 minutes.
- The PR takes about 5 minutes.

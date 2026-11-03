# Resolve conflicts

List unmerged paths first.

```bash
git diff --name-only --diff-filter=U
```

Resolve one path at a time.

Record the choice for the path.
Then stage the path.

```bash
git add <path>
```

Do not use `git checkout --ours` or `--theirs` on a whole directory.

## Three choices

Pick one choice per path.

1. Keep-rule. Keep Stream behavior. Adopt the new API.
2. Take upstream. The only delta is format, a rename, or a deleted API.
3. Honor a prior Stream delete. Do not restore that file.

Stop on a path when none of the three choices fit.

Ask one question about that path.

Name the behavior that would change.

## High-risk paths

Stop on these paths when the two sides disagree about a version or a symbol.

1. `DEPS`
2. `sdk/BUILD.gn`
3. `sdk/android/BUILD.gn`
4. A public ObjC header
5. A public JNI signature

For other `BUILD.gn` files, union the deps.

Keep Stream-only targets.

Drop a duplicate dep.

## Public API

Do not delete a public ObjC symbol.

Do not delete a public JNI symbol.

When upstream deleted the native feature, leave the symbol in place.

Make the deleted feature inert.

Record that stub as a risk.

## After the conflicts

A later compile break is not a merge conflict.

Fix Stream-owned files that fail the new API.

Record each fix as a decision.

When the compiler rejects a Stream file for unsafe buffers, add that path to the existing exempt list.

Keep the addition in one labeled block.

Do not exempt an official file that upstream still checks.

Record the exempt path as debt.

## Past examples

These choices are examples from M145 and M148.

Do not replay them as a patch list.

1. Keep a Stream callback. Adopt the new base class and types.
2. Keep a Stream field on an encoder. Do not restore a helper that Stream deleted.
3. Take an upstream format-only change in Metal renderers.
4. Union new upstream deps with existing Stream deps.
5. Leave a deleted public flag in the API and make it inert.

## Abort one file

When a resolution is wrong, restore that path and choose again.

```bash
git checkout -m -- <path>
```

Do not abort the whole merge after some paths are already staged.

Abort the whole merge only for the rules in [merge-forward.md](merge-forward.md).

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

In `sdk/android/BUILD.gn`, keep `dist_jar("libwebrtc")` on `direct_deps_only = false` with `jar_excluded_patterns = stream_android_jar_excluded_patterns`.

Keep the `stream_android_jar.gni` import.

Do not take upstream `direct_deps_only = true`. It drops the generated jni_zero `*Jni` classes and the AAR crashes at runtime.

When packaging reports a package outside the allowlist, add it to `extensions/android/stream_android_jar.gni`.

Keep `:libwebrtc_final_jni_java` in the `libwebrtc` deps, declared as `java_library` with `supports_android` and `requires_android`. It packs jni_zero's `GEN_JNI` and `J.N`. `rtc_android_library` strips `GEN_JNI.class` because the srcjar dep name contains `jni`. Without `GEN_JNI` the AAR crashes in `PeerConnectionFactory.initialize`.

Keep `java_targets = [ ":libwebrtc_java_targets" ]` on `libjingle_peerconnection_so`.

When a Java target joins `libwebrtc_java_targets`, link its `*_jni` target into `libjingle_peerconnection_so`.

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

## Silent upstream rules

Some upstream changes break Stream files with no conflict and no compile error.

Upstream applies them to its own files in the same roll.

1. Find official commits in the merge that touch many files with the same edit.
2. List the Stream-added files of the same kind.
3. Apply the same edit to each one.
4. Record each edit as a decision.

M156 example: jni_zero emits Java-to-native entry points only inside `DEFINE_JNI(<Class>)`, and only for `@NativeMethods` interfaces. Upstream added `DEFINE_JNI` to its JNI files and moved its plain `native` methods into `@NativeMethods` interfaces. `EncryptionManager` and `LibaomAv1Encoder` were Stream-only, so their plain `native` methods compiled and linked with no `Java_*` export, and E2EE and AV1 threw `UnsatisfiedLinkError`.

Run this check after the conflicts. It needs no build.

```bash
stream_build/scripts/check-android-jni.sh --src .
```

It reports a missing `DEFINE_JNI`, a plain `native` method in a `generate_jni` source, and a Java/native `generate_jni` mismatch.

Fix each report, or record why it is safe.

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

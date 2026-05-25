## Summary

<!--
One or two sentences: what changed and why. Skip the play-by-play.
The diff already shows what; this section should explain why.
-->

## Validation

<!--
What you actually ran and what you actually saw, not what you intended to run.
Examples:

  xcodebuild test -project Cotabby.xcodeproj -scheme Cotabby \
    -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
  # ** TEST SUCCEEDED **  N tests, 0 failures

  swiftlint lint --config .swiftlint.yml --quiet
  # exit 0

For UI changes, attach a screenshot or short screen recording.
For changes that can't be verified end-to-end yet, say so explicitly.
-->

## Linked issues

<!--
Use `Fixes #N` to auto-close on merge, `Refs #N` to link without closing.
-->

## Risk / rollout notes

<!--
Anything reviewers should know that isn't visible from the diff:
- Schema, settings, or pbxproj migrations
- Behavior changes that touch existing user flows
- Performance characteristics worth flagging
- Follow-up issues filed (link them)

Skip this section entirely if there's nothing to flag.
-->

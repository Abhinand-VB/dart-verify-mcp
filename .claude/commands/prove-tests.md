---
description: Show that new or changed tests fail without the change, and strengthen the ones that do not
argument-hint: "[base ref, default: HEAD]"
---

Run the `prove_tests_can_fail` tool from the dart-verify MCP server with
`project_root` set to the absolute path of the current project and
`base_ref` set to $ARGUMENTS (use `HEAD` if no argument was given, which
checks uncommitted work; use the branch point, e.g. `main`, for committed
work).

Read `needs_attention` and handle each entry by its verdict:

- `PASSES_ON_BASE`: the test passes without the change, so it may not test
  the change at all. Read the test and the diff. Decide which of these it is:
  - It does not exercise the changed behaviour (it asserts something the old
    code already did, or it echoes its own input back). Rewrite it so it
    asserts the new behaviour, then confirm it now fails on base.
  - It is a deliberate guard that pins behaviour which already worked (a
    regression test written alongside the change). That is legitimate. Keep
    it, and say in your summary that it is a guard, not proof of the change.
  Never "fix" this verdict by making the test weaker or by changing the base
  ref.
- `FAILS_ON_CURRENT`: the test fails on the current code. Either the code or
  the test is wrong. Fix that first; nothing else in the report means much
  until it passes.
- `INCONCLUSIVE` or `SKIPPED`: say why (the `detail` field) and whether it
  needs action.

`FAILS_ON_BASE` is the good outcome. `ERROR` means the test did not compile
on the base ref, usually because it calls code that did not exist yet; that
counts as detecting the change, but if the new code has behaviour that could
also be tested against the old API, consider adding such a test.

After changing any test, run `prove_tests_can_fail` again, then run the gate
(`run_gate`). Report the final verdict counts, and name any test you kept as
a guard.

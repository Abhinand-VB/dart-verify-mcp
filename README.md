# dart_verify_mcp

An MCP server, plus three Claude Code slash commands, that gives a coding
agent working on a Dart or Flutter project four checks it would otherwise
have to be trusted on:

| Tool | Question it answers |
|------|---------------------|
| `prove_tests_can_fail` | Do the new tests fail without the change, or would they pass anyway? |
| `check_layers` | Does any file import something its layer is not allowed to import? |
| `unused_dependencies` | Which declared dependencies does nothing import, and is there another reason to keep them? |
| `run_gate` | Did every step of the project's definition of done pass? (`done: true` or not) |

Each tool returns a short human summary and a JSON report (also sent as MCP
`structuredContent`). It is meant to run next to the official Dart MCP
server, not instead of it.

## Why it exists

I built a Flutter app, Van, with Claude Code agents working from written
specs, often overnight. The agents were productive, and the places where
that went wrong were all places where a claim was accepted without a check:

- **A test that could not fail.** An agent fixed a bug in how Van picks
  notification wording and wrote a test for it. The test passed against the
  broken code too: it compared the level inside `templateId` with the level
  requested, and `templateId` was built from the request. It was caught only
  because of a habit of reverting each fix and re-running its test. That
  habit is `prove_tests_can_fail`.
- **Architecture rules are only real if a check fails the build.** Van keeps
  its domain core in a pure Dart package and had a script,
  `tool/check_layers.dart`, that failed CI if the core imported Flutter,
  `dart:io` or other platform code. `check_layers` generalizes that script
  into config.
- **Dependencies nobody imports.** Van declares `flutter_riverpod`,
  `flutter_secure_storage` and `android_alarm_manager_plus` without importing
  any of them. Nothing noticed. That is `unused_dependencies`.
- **Green tests are not "done".** One night took the suite from 263 to 575
  passing tests while the phone was running a stale build, and the app was
  unusable in the morning. A gate cannot see a phone either, but it can make
  "done" one explicit answer that includes every step you decide counts, so
  "the tests pass" stops standing in for it. That is `run_gate`.

## How it relates to `dart mcp-server`

The Dart SDK ships an MCP server (`dart mcp-server`). On Dart 3.11.5 it
exposes, among others, `analyze_files`, `run_tests`, `dart_format`,
`dart_fix`, `pub`, `pub_dev_search`, `create_project`, `hover`,
`signature_help`, `resolve_workspace_symbol`, and app tools such as
`launch_app`, `hot_reload` and `get_widget_tree`. Use it for running and
inspecting code.

This server does not repeat any of that. It answers questions those tools
do not ask: whether a test can fail, whether imports respect layers, whether
a dependency is used, and whether all of it together is green. `run_gate`
does run `dart format`, `dart analyze` and the tests, but only as steps of
one pass/fail answer.

## Install and register

Requires the Dart SDK (3.11 or newer) and `git`. Flutter is needed only for
Flutter projects.

```sh
git clone https://github.com/Abhinand-VB/dart-verify-mcp
cd dart-verify-mcp
dart pub get
mkdir build
dart compile exe bin/dart_verify_mcp.dart -o build/dart_verify_mcp.exe
```

Register it next to the Dart server in the project's `.mcp.json` (use the
absolute path to the compiled binary; on macOS and Linux you can drop the
`.exe` suffix from both lines):

```json
{
  "mcpServers": {
    "dart": {
      "command": "dart",
      "args": ["mcp-server"]
    },
    "dart-verify": {
      "command": "/absolute/path/to/dart-verify-mcp/build/dart_verify_mcp.exe"
    }
  }
}
```

Running from source also works, with a slower start:
`"command": "dart", "args": ["run", "/absolute/path/to/dart-verify-mcp/bin/dart_verify_mcp.dart"]`.

Two things I ran into:

- **Do not register it through `dart pub global activate --source path`.**
  When I tried that, `dart pub global run` printed its dependency
  resolution to stdout before the server started, and stdout is the MCP
  protocol stream.
- **`prove_tests_can_fail` and `run_gate` can take minutes** on a Flutter
  project. Each step has its own timeout on the server side; if your client
  gives up first, raise its limit (Claude Code reads `MCP_TOOL_TIMEOUT`, in
  milliseconds).

To try a tool without an agent, `tool/call_tool.dart` starts the server and
calls one tool over stdio. Every example output below was captured this way:

```sh
dart run tool/call_tool.dart --list
dart run tool/call_tool.dart unused_dependencies '{"project_root": "/path/to/app"}'
```

## The tools

### `prove_tests_can_fail`

Inputs: `project_root`, `base_ref` (default `HEAD`), optional `test_files`,
`check_current` (default true), `only_changed_tests` (default true),
`timeout_seconds`.

1. Finds the `*_test.dart` files added or modified relative to `base_ref`
   (`git diff --name-status` plus untracked files), or uses `test_files`.
2. Creates a temporary `git worktree` at `base_ref` under the system temp
   directory and copies the new versions of those tests into it, along with
   any changed helpers under the same package's `test/`, because helpers
   belong to the test rather than to the code under test.
3. Runs `dart pub get` or `flutter pub get` there (at the workspace root for
   pub workspace members), then each test file with `--reporter json`, from
   the nearest `pubspec.yaml` above it. Flutter is detected from
   `sdk: flutter` in that pubspec.
4. With `check_current`, does the same in a second worktree that holds the
   full working-tree state, so a test that fails everywhere is not mistaken
   for one that detects the change. The user's checkout is never written to.
5. Removes both worktrees in a `finally` block, including on failure or
   timeout.

Verdicts, per test:

| Verdict | Meaning |
|---------|---------|
| `FAILS_ON_BASE` | Fails on the old code, passes now. The test detects the change. |
| `PASSES_ON_BASE` | Passes on the old code too. It may not test the change. Look at it. |
| `ERROR` | Did not load on the old code, usually because it calls code that did not exist yet. Counts as detecting the change, labelled separately because "does not compile" is a weaker signal than "runs and fails". |
| `FAILS_ON_CURRENT` | Fails on the current code. Failing on base proves nothing for such a test. Reported even for unchanged tests in the file, since the change broke them. |
| `SKIPPED` / `INCONCLUSIVE` | Skipped, timed out, or the environment could not be prepared. |

In a test file that already existed at `base_ref`, only the tests whose
lines changed are judged; the rest are listed with `in_diff: false`. A test's
lines are found from indentation (its `test(` call through the matching
closing line), which fits `dart format` output.

`PASSES_ON_BASE` is a prompt to look, not a verdict that the test is wrong.
A regression guard written alongside a change pins behaviour that already
worked, and passing on base is exactly what it should do.

**Run against the real Van commit.** Van's history has the fix described
above as commit `7ba87de`. Running the tool on a throwaway clone at that
commit, with the parent as base:

```
prove_tests_can_fail vs 7ba87de~1 (42f5139): 4 changed test(s) in 1 file(s) (27 unchanged test(s) not judged). 1 FAILS_ON_BASE, 3 PASSES_ON_BASE.
  PASSES_ON_BASE: test/inference/inference_test.dart:112: every level keeps its own tone no combination silently answers as l0Gentle
  PASSES_ON_BASE: test/inference/inference_test.dart:164: every level keeps its own tone a real entry is still preferred over the fallback
  PASSES_ON_BASE: test/inference/inference_test.dart:179: every level keeps its own tone the last resort still answers when the bank is empty
```

The test at line 112 is the one the night log describes: it reads the level
out of `templateId`, and on the old code `templateId` echoed the request, so
it passes there. The test that actually catches the bug is the one at line
140, reported in the JSON as:

```json
{
  "name": "every level keeps its own tone the id names the line that was actually used",
  "line": 140,
  "verdict": "FAILS_ON_BASE",
  "in_diff": true,
  "base_result": "failure",
  "current_result": "success",
  "detail": "Fails on base (failure): Expected: a string starting with 'sessionMissed_l5Concede#'."
}
```

The other two `PASSES_ON_BASE` tests are guards for behaviour the fix had
to keep, which is the legitimate case described above.

**On uncommitted work.** On another clone I made a small change to Van's
pure core (`FakeClock.advanceTo` accepting the current instant, plus a new
`startedAt` getter) and wrote three tests for it, the way an agent might,
including a bug in `startedAt`:

```
prove_tests_can_fail vs HEAD (92cc7f0): 3 changed test(s) in 2 file(s) (11 unchanged test(s) not judged). 1 FAILS_ON_BASE, 1 PASSES_ON_BASE, 1 FAILS_ON_CURRENT.
  FAILS_ON_CURRENT: packages/van_core/test/clock_start_test.dart:5: startedAt remembers the first instant
  FAILS_ON_CURRENT: packages/van_core/test/clock_test.dart:61: FakeClock advanceTo rejects the current instant
  PASSES_ON_BASE: packages/van_core/test/clock_test.dart:75: FakeClock advanceTo still moves to a later instant
```

The first line is the bug in the new getter. The second is an existing,
unchanged test that the behaviour change broke. After fixing the getter and
removing the obsolete test:

```
prove_tests_can_fail vs HEAD (92cc7f0): 3 changed test(s) in 2 file(s) (10 unchanged test(s) not judged). 1 FAILS_ON_BASE, 1 PASSES_ON_BASE, 1 ERROR.
  PASSES_ON_BASE: packages/van_core/test/clock_test.dart:67: FakeClock advanceTo still moves to a later instant
```

with the `ERROR` entry explained as `Did not load on base, which usually
means it references code that did not exist yet: test/clock_start_test.dart:8:18:
Error: The getter 'startedAt' isn't defined for the type 'FakeClock'.` Note
that the test in `packages/van_core` ran with `dart test` from that nested
package, while the Van commit above ran with `flutter test`.

### `check_layers`

Reads the `layers` section of `verify_gate.yaml` and checks every Dart file
each layer's `paths` select. For each layer:

- `forbid`: URI patterns no import or export may match.
- `allow`: if present, every import or export with a scheme (`dart:`,
  `package:`) must match one of these.
- `forbid_code`: regexes that must not match the code with comments removed.
- `exclude`, `reason`.

URIs come from a small lexer, not a regex per line, so imports inside
comments or strings are ignored, a directive split across lines is read,
and every URI of a conditional import (`if (dart.library.io) 'dart:io'`) is
checked. Relative imports are resolved to their `package:` form, so
forbidding `package:app/ui/` also catches `import '../ui/screen.dart'`. A
pattern matches at a path boundary: `package:flutter` matches
`package:flutter/material.dart` but not `package:flutter_riverpod/...`. `*`
matches within one path segment.

Van's three rules from `tool/check_layers.dart`, as config:

```yaml
layers:
  - name: A - core purity (ARCHITECTURE.md P1)
    paths: [packages/van_core/lib]
    allow:
      - 'dart:core'
      - 'dart:math'
      - 'dart:async'
      - 'dart:collection'
      - 'dart:convert'
      - 'dart:typed_data'
      - 'package:meta/'
      - 'package:collection/'
      - 'package:van_core/'
    reason: >-
      van_core must stay runnable under plain `dart test` and liftable to a
      server.

  - name: B - no ambient time (ARCHITECTURE.md P2)
    paths: [lib, packages/van_core/lib]
    exclude:
      - lib/platform/system_clock.dart
      - lib/main.dart
      - '**.g.dart'
    forbid_code:
      - 'DateTime\s*\.\s*now\s*\('
    reason: Take a Clock in the constructor instead.

  - name: C - no provider names in core or ui (ARCHITECTURE.md 5.3)
    paths: [packages/van_core/lib, lib/ui]
    exclude: ['**.g.dart']
    forbid_code:
      - pattern: 'gemma|claude|anthropic|openai|gemini|litert|mediapipe'
        ignore_case: true
    reason: >-
      Talk to InferenceRouter and Capability instead; routing belongs in
      assets/inference_config.json.
```

On a clone of Van this reports `check_layers: OK. 3 rule(s) hold across 139
file check(s).`, matching Van's own script. I then added three violations to
the clone: a `DateTime.now()` in a repository, and two imports in the core,
one written across three lines and one inside a conditional import:

```dart
import
    'dart:io'
    show File;
import 'clock.dart'
    if (dart.library.ui) 'package:flutter/foundation.dart';
```

```
check_layers: 3 violation(s).
  lib/data/repositories/event_repo.dart:106 [B - no ambient time (ARCHITECTURE.md P2)] code matches forbidden pattern /DateTime\s*\.\s*now\s*\(/.
  packages/van_core/lib/src/result.dart:2 [A - core purity (ARCHITECTURE.md P1)] imports "dart:io", which is not in the allow list.
  packages/van_core/lib/src/result.dart:5 [A - core purity (ARCHITECTURE.md P1)] imports "package:flutter/foundation.dart" (if dart.library.ui), which is not in the allow list.
```

Van's original script, run on the same tree, reported only the first of the
three, because it matches `import '...'` on a single line and reads only the
first URI of a directive.

A rule whose `paths` match no files is reported as a warning (and fails the
`check_layers` gate step), because a typo in a glob otherwise looks exactly
like a clean codebase. With no layers configured, the JSON says
`"passed": null`, not `true`.

### `unused_dependencies`

Inputs: `project_root`, `include_dev` (default from config, else false),
`nested` (default true: every package under the root is checked against its
own sources, and nested packages are excluded from their parent's scan).

A dependency counts as used if any `.dart` file in the package (outside
`build/`, `.dart_tool/` and hidden directories) imports or exports
`package:<name>/`, including conditional imports, or an
`analysis_options*.yaml` includes `package:<name>/`. Everything else is
classified, not asserted:

- `likely_needed`, with a reason, when the package ships fonts or assets and
  has no Dart library (`cupertino_icons`), declares build_runner builders,
  is `build_runner`, is an FFI plugin or a federated platform
  implementation, is configured by a top-level `pubspec.yaml` section (for
  example `flutter_launcher_icons:`), is mentioned in the package's
  `build.yaml`, provides executables (dev dependencies only), or is a
  Flutter plugin whose native identifiers (its package name, Android
  package, plugin class) appear in the app's own `android/`, `ios/`,
  `macos/`, `windows/` or `linux/` sources. `GeneratedPluginRegistrant` and
  the other generated registrants are skipped, because they list every
  declared plugin.
- `allowlisted` when listed under `unused_dependencies.allow` with a reason.
- `unused_candidate` otherwise. The report says, every time, that a
  candidate is evidence and not proof.

Package details come from `.dart_tool/package_config.json`. Without
`pub get`, the tool falls back to judging a few well-known names and says so.

On Van (read-only, its own checkout):

```
unused_dependencies: 5 candidate(s) across 2 package(s).
  van (.):
    candidate: android_alarm_manager_plus (plugin)
    candidate: flutter_riverpod
    candidate: flutter_secure_storage (plugin)
    candidate: sqlite3_flutter_libs
    likely needed: cupertino_icons: ships fonts or assets and has no Dart library, so it is never imported
  van_core (packages/van_core):
    candidate: collection
  Candidates are not proof. Verify each before removing.
```

I checked each by hand:

| Package | Finding |
|---------|---------|
| `android_alarm_manager_plus` | No import. Its plugin class appears only in `GeneratedPluginRegistrant.java`; no Kotlin, Java or manifest reference; the plugin's own manifest is empty, so it merges nothing. Van's `STATUS.md` already says it is "currently unused". |
| `flutter_riverpod` | No import anywhere. |
| `flutter_secure_storage` | No import; only `GeneratedPluginRegistrant.java` mentions it. |
| `sqlite3_flutter_libs` | No import. Van resolves version `0.6.0+eol`, whose own description reads "Not used anymore, update to version 3.x of package:sqlite3 instead", and Van already resolves `sqlite3` 3.5.1. |
| `collection` (in `van_core`) | No import in `van_core`. Van's core-purity rule allows it, which is permission, not use. |

With `include_dev: true` it also lists `mocktail` as a candidate (no import
in Van's tests), and `build_runner` and `drift_dev` as likely needed
(`drift_dev` because its `build.yaml` declares builders).

### `run_gate`

Runs the `gate.steps` from `verify_gate.yaml`, or these defaults:

1. `dart format --output=none --set-exit-if-changed .` (reports unformatted
   files without rewriting them)
2. `dart analyze --fatal-infos`
3. `check_layers`, if any layers are configured
4. `dart test`, or `flutter test` for a Flutter package (a project with no
   `test/` directory fails this step instead of passing it vacuously)

Every step runs (unless `fail_fast`), each with a timeout after which its
process tree is killed, and the result is `done: true` only if every step
passed. Output is trimmed from the front, with test-runner progress lines
condensed, so the failure at the end survives.

This repository's own gate (`verify_gate.yaml`):

```
run_gate: DONE. All 5 step(s) passed.
  passed    format (1.1s)
  passed    analyze (2.9s)
  passed    layers (0.1s)
  passed    dependencies (0.0s)
  passed    test (33.4s)
```

On a clone of Van with the layer config above and the default steps:

```
run_gate: DONE. All 4 step(s) passed.
  passed    format (2.4s)
  passed    analyze (29.5s)
  passed    check_layers (0.3s)
  passed    test (44.7s)
```

(591 tests at Van commit `92cc7f0`.) If running on a device is part of
done for your project, put that in the gate as a step, for example an
`integration_test` run or a script that builds and installs the app.

## `verify_gate.yaml`

Optional, at the project root. A file that exists but cannot be parsed is an
error, never silently replaced by defaults.

```yaml
layers:
  - name: domain has no Flutter or IO
    paths: [lib/domain]            # globs; a bare directory means everything under it
    exclude: ['**.g.dart']
    forbid: ['package:flutter/', 'dart:io', 'package:my_app/ui/']
    reason: The domain layer is tested with plain dart test.

unused_dependencies:
  include_dev: false
  allow:
    - flutter_native_splash: run by hand when the splash changes

prove_tests:
  # Commands run in each worktree after pub get, for projects that do not
  # commit generated code.
  setup: ['dart run build_runner build -d']
  timeout_seconds: 600             # per test file, per worktree

gate:
  timeout_seconds: 600             # default per step
  steps:
    - name: format
      run: dart format --output=none --set-exit-if-changed .
    - name: analyze
      run: dart analyze --fatal-infos
    - name: layers
      builtin: check_layers
    - name: dependencies
      builtin: unused_dependencies   # fails if there are candidates
    - name: test
      run: flutter test
      timeout_seconds: 1800
```

`run` is split into words (quotes are honoured) and executed without a
shell, so pipes, globs and `&&` do not work; use a script for those. A list
(`run: [dart, run, tool/x.dart]`) is also accepted.

## Slash commands

`.claude/commands/` holds three Claude Code commands. Copy them into a
project's `.claude/commands/` (or `~/.claude/commands/`) to use them there.
They tell the agent what to do with each result, which the tools alone do
not:

- `/verify`: run `run_gate`; never describe the task as done unless
  `done: true`; on red, show the failing step and fix the cause without
  weakening the gate (no editing `verify_gate.yaml`, skipping tests or adding
  ignores unless the user asks).
- `/prove-tests [base-ref]`: run `prove_tests_can_fail`; rewrite each
  `PASSES_ON_BASE` test that does not exercise the change until it fails on
  base, keep deliberate guards and say which they are, fix
  `FAILS_ON_CURRENT` first, then re-run the gate.
- `/deps-hygiene [--dev]`: run `unused_dependencies`; for each candidate,
  search the repository, native code, build config and docs before removing
  it with `dart pub remove` / `flutter pub remove`, one at a time, re-running
  the gate after each.

## Limitations

These are heuristics with known gaps. The reports say what they could not
see, but read this list before trusting one.

**prove_tests_can_fail**

- Needs `git`. Worktrees are created in the system temp directory; while the
  tool runs, git also records them under `.git/worktrees/`, and they are
  removed and pruned at the end. A process killed mid-run can leave one
  behind (`git worktree prune` cleans it up).
- Worktrees contain only what git tracks. Generated files that are
  gitignored (for example `*.g.dart` in projects that do not commit them)
  are missing on base, so tests will not compile there. Use
  `prove_tests.setup` to regenerate them. Git submodules are not checked out.
- It runs each test file twice (base and current), plus `pub get` in each
  worktree, so it is slow on large Flutter suites. Pass `test_files` to
  narrow it.
- Attributing tests to changed lines uses indentation. A change to a helper
  or `setUp` outside any test body is counted and mentioned, but not
  attributed to the tests that use it. Pass `only_changed_tests: false` to
  judge every test in the file.
- A deleted test is invisible to it. A flaky test can produce any verdict.
  Tests that depend on files outside the repository behave as they would in
  a fresh checkout.
- `ERROR` means "did not load", which is almost always "references new
  code", but a test can also fail to load on base for unrelated reasons.
  The detail field has the compiler message.

**check_layers**

- The scanner is a lexer, not the Dart analyzer. It handles comments,
  every string form, multi-line and conditional directives, but it does not
  resolve `export` chains: importing a library that re-exports a forbidden
  one is not caught.
- `forbid_code` matches one line at a time, against code with comments
  removed and strings kept (as Van's script did). A pattern cannot span
  lines.

**unused_dependencies**

- "No import" is the core signal. A package can be needed without one in
  ways it does not detect: used only from a script outside the package, run
  from CI by name, kept to pin a transitive version, used only by native
  code under a name that does not match its identifiers, or used only by
  generated code that is not checked in.
- Native-source matching is plain text search, so a mention in a comment
  counts as a reference.
- The name-based fallback (without `pub get`) knows only a handful of names.

**run_gate**

- Steps run without a shell. On Windows, a command resolves through `PATH`
  the way `cmd.exe` would, and batch files such as `flutter.bat` run through
  `cmd.exe`; everything else runs directly.
- On timeout, Windows kills the whole process tree (`taskkill /T /F`). On
  macOS and Linux it kills the direct children (`pkill -P`) and the process
  itself; deeper descendants can survive.

**Platforms**

All development, and every output in this README, is from Windows 11 with
Dart 3.11.5 and Flutter 3.41.9. The CI workflow runs format, analyze and the
full test suite on Linux, macOS and Windows.

## Development

```sh
dart pub get
dart test            # includes tests tagged `slow`, which build git repos and run pub get
dart test -x slow    # the fast loop
dart run tool/call_tool.dart run_gate '{"project_root": "."}'
```

The core of each tool is a plain function in `lib/src/` (`proveTestsCanFail`,
`checkLayers`, `findUnusedDependencies`, `runGate`); `lib/src/server.dart` is
the only file that knows about MCP, and this repository's own
`verify_gate.yaml` enforces that.

## License

MIT. See [LICENSE](LICENSE).

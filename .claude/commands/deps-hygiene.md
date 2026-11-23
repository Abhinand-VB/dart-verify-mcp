---
description: Find dependencies nothing imports, verify each one, and remove only the ones that are really unused
argument-hint: "[--dev to include dev_dependencies]"
---

Run the `unused_dependencies` tool from the dart-verify MCP server with
`project_root` set to the absolute path of the current project. If
$ARGUMENTS contains `--dev`, set `include_dev: true`.

The tool reports `unused_candidate` entries. A candidate has no
`package:` import or export, but that is not proof it is unused. For EACH
candidate, before removing anything:

1. Search the whole repository for the package name, not only Dart files:
   `grep -rn "<name>" --include=* .` excluding `.dart_tool/`, `build/`,
   `pubspec.lock` and `GeneratedPluginRegistrant.*` / `generated_plugin*`
   (those list every declared plugin and prove nothing).
2. For a Flutter plugin (the tool marks these), read the native side:
   `android/app/src/main/AndroidManifest.xml`, Kotlin/Java under
   `android/app/src/`, Swift/Objective-C under `ios/Runner/` and
   `macos/Runner/`, and Gradle files. Look for the plugin's classes,
   services, receivers, or permissions it requires.
3. Check build and tooling config: `build.yaml`, top-level sections of
   `pubspec.yaml`, CI workflows, scripts, Makefiles, and `README`/docs that
   tell people to `dart run <name>`.
4. Check whether the project's own docs say the dependency is intentionally
   kept for future work. If so, ask the user instead of removing it.

Only when all of that comes back empty, remove it with
`flutter pub remove <name>` for a Flutter package or `dart pub remove <name>`
otherwise, one package at a time. After each removal run the `run_gate` tool.
If anything goes red, restore the dependency with `pub add` at the previous
version constraint and record why it is needed.

For a dependency that must stay despite having no import, add it to
`unused_dependencies.allow` in `verify_gate.yaml` with the reason, so the
next run does not report it again.

Finish with a table: package, verdict (removed / kept / allowlisted), and
the evidence for that verdict. Do not remove `likely_needed` entries without
checking the reason the tool gave and asking the user.

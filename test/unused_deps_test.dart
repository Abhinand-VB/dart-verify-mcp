import 'package:dart_verify_mcp/dart_verify_mcp.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  late String root;
  late String pub;

  /// Creates a fake resolved package under [pub].
  void fakePackage(
    String name, {
    String pubspecExtra = '',
    Map<String, String> files = const {},
    bool lib = true,
  }) {
    writeFiles(p.join(pub, name), {
      'pubspec.yaml': 'name: $name\n$pubspecExtra',
      if (lib) 'lib/$name.dart': '',
      ...files,
    });
  }

  setUp(() {
    final base = tempDir();
    root = p.join(base, 'app');
    pub = p.join(base, 'pub');
    writeFiles(root, {
      'pubspec.yaml': '''
name: app
dependencies:
  flutter:
    sdk: flutter
  used_pkg: any
  exported_pkg: any
  conditional_pkg: any
  unused_pkg: any
  icons_font: any
  native_plugin: any
  orphan_plugin: any
  ffi_libs: any
  allowed_pkg: any
  impl_pkg: any
  launcher_tool: any
dev_dependencies:
  test_only: any
  lints_pkg: any
  gen_builder: any
  cli_tool: any
  unused_dev: any
launcher_tool:
  image_path: icon.png
''',
      'analysis_options.yaml': 'include: package:lints_pkg/recommended.yaml\n',
      'lib/main.dart': '''
import 'package:flutter/material.dart';
// import 'package:unused_pkg/unused_pkg.dart';
import 'package:used_pkg/used_pkg.dart'
    show thing;
import 'stub.dart' if (dart.library.io) 'package:conditional_pkg/io.dart';
const s = "import 'package:unused_dev/x.dart';";
''',
      'lib/api.dart': "export 'package:exported_pkg/exported_pkg.dart';\n",
      'test/a_test.dart': "import 'package:test_only/test_only.dart';\n",
      'android/app/src/main/kotlin/com/example/MainActivity.kt': '''
package com.example
import com.example.nativeplugin.NativePlugin
''',
      'android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java':
          'new com.example.orphan.OrphanPlugin();\n',
      // A nested package: its imports must not count for the root package,
      // and its own dependencies are judged against its own files.
      'packages/inner/pubspec.yaml': '''
name: inner
dependencies:
  inner_dep: any
''',
      'packages/inner/lib/inner.dart':
          "import 'package:unused_pkg/unused_pkg.dart';\n",
    });
    for (final n in [
      'used_pkg',
      'exported_pkg',
      'conditional_pkg',
      'unused_pkg',
      'allowed_pkg',
      'test_only',
      'unused_dev',
      'inner_dep',
    ]) {
      fakePackage(n);
    }
    fakePackage(
      'icons_font',
      lib: false,
      pubspecExtra: '''
flutter:
  fonts:
    - family: Icons
      fonts:
        - asset: assets/icons.ttf
''',
    );
    fakePackage(
      'native_plugin',
      pubspecExtra: '''
flutter:
  plugin:
    platforms:
      android:
        package: com.example.nativeplugin
        pluginClass: NativePlugin
''',
    );
    fakePackage(
      'orphan_plugin',
      pubspecExtra: '''
flutter:
  plugin:
    platforms:
      android:
        package: com.example.orphan
        pluginClass: OrphanPlugin
''',
    );
    fakePackage(
      'ffi_libs',
      pubspecExtra: '''
flutter:
  plugin:
    platforms:
      android:
        ffiPlugin: true
''',
    );
    fakePackage(
      'impl_pkg',
      pubspecExtra: '''
flutter:
  plugin:
    implements: some_plugin
    platforms:
      android:
        package: com.example.impl
        pluginClass: ImplPlugin
''',
    );
    fakePackage('launcher_tool', files: {'bin/launcher_tool.dart': ''});
    fakePackage('lints_pkg', lib: false, files: {'lib/recommended.yaml': ''});
    fakePackage(
      'gen_builder',
      files: {'build.yaml': 'builders:\n  gen:\n    import: x\n'},
    );
    fakePackage('cli_tool', files: {'bin/cli_tool.dart': ''});
    writePackageConfig(root, {
      for (final n in [
        'used_pkg',
        'exported_pkg',
        'conditional_pkg',
        'unused_pkg',
        'icons_font',
        'native_plugin',
        'orphan_plugin',
        'ffi_libs',
        'allowed_pkg',
        'impl_pkg',
        'launcher_tool',
        'test_only',
        'lints_pkg',
        'gen_builder',
        'cli_tool',
        'unused_dev',
        'inner_dep',
      ])
        n: p.join(pub, n),
    });
  });

  Map<String, DepFinding> findingsFor(UnusedDepsReport r, String pkg) => {
    for (final f in r.packages.singleWhere((x) => x.name == pkg).findings)
      f.name: f,
  };

  test('classifies dependencies without imports', () {
    final report = findUnusedDependencies(
      root,
      allow: {'allowed_pkg': 'kept on purpose'},
    );
    final f = findingsFor(report, 'app');

    // Used through import, export, conditional import: not reported at all.
    for (final used in [
      'used_pkg',
      'exported_pkg',
      'conditional_pkg',
      'flutter',
    ]) {
      expect(f, isNot(contains(used)), reason: used);
    }

    expect(f['unused_pkg']!.status, DepStatus.unusedCandidate);
    expect(f['orphan_plugin']!.status, DepStatus.unusedCandidate);
    expect(f['orphan_plugin']!.isPlugin, isTrue);
    expect(f['orphan_plugin']!.reason, contains('GeneratedPluginRegistrant'));

    expect(f['native_plugin']!.status, DepStatus.likelyNeeded);
    expect(f['native_plugin']!.evidence.single, endsWith('MainActivity.kt:2'));
    expect(f['icons_font']!.status, DepStatus.likelyNeeded);
    expect(f['icons_font']!.reason, contains('fonts'));
    expect(f['ffi_libs']!.status, DepStatus.likelyNeeded);
    expect(f['impl_pkg']!.status, DepStatus.likelyNeeded);
    expect(f['impl_pkg']!.reason, contains('some_plugin'));
    expect(f['launcher_tool']!.status, DepStatus.likelyNeeded);
    expect(f['launcher_tool']!.reason, contains('`launcher_tool:` section'));
    expect(f['allowed_pkg']!.status, DepStatus.allowlisted);
    expect(f['allowed_pkg']!.reason, 'kept on purpose');

    // dev_dependencies are not checked by default.
    expect(f, isNot(contains('unused_dev')));
    expect(
      report.packages.singleWhere((x) => x.name == 'app').used['used_pkg'],
      'lib/main.dart:3',
    );
  });

  test('checks dev_dependencies on request', () {
    final f = findingsFor(
      findUnusedDependencies(root, includeDev: true),
      'app',
    );
    expect(f, isNot(contains('test_only')));
    expect(f, isNot(contains('lints_pkg'))); // analysis_options include
    expect(f['gen_builder']!.status, DepStatus.likelyNeeded);
    expect(f['gen_builder']!.reason, contains('builders'));
    expect(f['cli_tool']!.status, DepStatus.likelyNeeded);
    expect(f['cli_tool']!.reason, contains('executables'));
    expect(f['unused_dev']!.status, DepStatus.unusedCandidate);
  });

  test('keeps nested packages separate', () {
    final report = findUnusedDependencies(root);
    expect(report.packages.map((x) => (x.name, x.dir)), [
      ('app', '.'),
      ('inner', 'packages/inner'),
    ]);
    // inner imports unused_pkg, but that does not make it used by app.
    expect(
      findingsFor(report, 'app')['unused_pkg']!.status,
      DepStatus.unusedCandidate,
    );
    expect(
      findingsFor(report, 'inner')['inner_dep']!.status,
      DepStatus.unusedCandidate,
    );
    expect(findUnusedDependencies(root, nested: false).packages, hasLength(1));
  });

  test('without pub get, falls back to name-only judgement and says so', () {
    final bare = tempDir();
    writeFiles(bare, {
      'pubspec.yaml': '''
name: bare
dependencies:
  cupertino_icons: any
  mystery: any
dev_dependencies:
  build_runner: any
  json_generator: any
''',
    });
    final report = findUnusedDependencies(bare, includeDev: true);
    final pkg = report.packages.single;
    final f = {for (final x in pkg.findings) x.name: x};
    expect(f['cupertino_icons']!.status, DepStatus.likelyNeeded);
    expect(f['cupertino_icons']!.reason, contains('by name only'));
    expect(f['build_runner']!.status, DepStatus.likelyNeeded);
    expect(f['json_generator']!.status, DepStatus.likelyNeeded);
    expect(f['mystery']!.status, DepStatus.unusedCandidate);
    expect(f['mystery']!.reason, contains('pub get'));
    expect(pkg.toJson()['warning'], contains('pub get'));
    expect(report.candidateCount, 1);
    expect(report.summary(), contains('not proof'));
  });
}

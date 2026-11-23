import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// The subset of a `pubspec.yaml` this tool reads.
class Pubspec {
  Pubspec({
    required this.dir,
    required this.name,
    required this.dependencies,
    required this.devDependencies,
    required this.topLevelKeys,
    required this.raw,
  });

  /// Absolute directory holding the pubspec.
  final String dir;
  final String name;

  /// Dependency name to its raw spec (a version string, or a map such as
  /// `{sdk: flutter}` or `{path: ../x}`).
  final Map<String, Object?> dependencies;
  final Map<String, Object?> devDependencies;
  final Set<String> topLevelKeys;
  final Map<Object?, Object?> raw;

  /// True when the package depends on the Flutter SDK, which decides between
  /// `dart test` and `flutter test`.
  bool get isFlutter => _isSdk(dependencies['flutter'], 'flutter');

  /// True for a member of a pub workspace (`resolution: workspace`), whose
  /// `pub get` has to run at the workspace root.
  bool get isWorkspaceMember => raw['resolution'] == 'workspace';

  static bool _isSdk(Object? spec, String sdk) =>
      spec is Map && spec['sdk'] == sdk;

  static bool isSdkDependency(Object? spec) =>
      spec is Map && spec['sdk'] != null;

  static Pubspec load(String dir) {
    final file = File(p.join(dir, 'pubspec.yaml'));
    return parse(file.readAsStringSync(), dir: p.normalize(dir));
  }

  static Pubspec parse(String text, {required String dir}) {
    final doc = loadYaml(text);
    if (doc is! Map) {
      throw FormatException('pubspec.yaml in $dir is not a mapping');
    }
    Map<String, Object?> deps(Object? v) => v is Map
        ? {for (final e in v.entries) e.key.toString(): _plain(e.value)}
        : {};
    return Pubspec(
      dir: dir,
      name: doc['name']?.toString() ?? p.basename(dir),
      dependencies: deps(doc['dependencies']),
      devDependencies: deps(doc['dev_dependencies']),
      topLevelKeys: {for (final k in doc.keys) k.toString()},
      raw: _plain(doc) as Map<Object?, Object?>,
    );
  }

  static Object? _plain(Object? v) {
    if (v is Map) {
      return {for (final e in v.entries) e.key: _plain(e.value)};
    }
    if (v is List) return [for (final e in v) _plain(e)];
    return v;
  }
}

/// Resolves package names to their root directories using the
/// `.dart_tool/package_config.json` written by `pub get`.
class PackageConfig {
  PackageConfig(this.roots);

  final Map<String, String> roots;

  /// Looks for a package config in [packageDir] and then in each parent
  /// (pub workspaces keep one at the workspace root). Returns null if pub get
  /// has not been run.
  static PackageConfig? find(String packageDir) {
    var dir = p.normalize(p.absolute(packageDir));
    while (true) {
      final f = File(p.join(dir, '.dart_tool', 'package_config.json'));
      if (f.existsSync()) return _read(f);
      final parent = p.dirname(dir);
      if (parent == dir) return null;
      dir = parent;
    }
  }

  static PackageConfig? _read(File f) {
    try {
      final json = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
      final base = Uri.file(p.dirname(f.absolute.path) + p.separator);
      final roots = <String, String>{};
      for (final pkg in (json['packages'] as List? ?? const [])) {
        if (pkg is! Map) continue;
        final name = pkg['name'];
        final rootUri = pkg['rootUri'];
        if (name is! String || rootUri is! String) continue;
        final resolved = base.resolve(
          rootUri.endsWith('/') ? rootUri : '$rootUri/',
        );
        if (resolved.scheme != 'file') continue;
        roots[name] = p.normalize(resolved.toFilePath());
      }
      return PackageConfig(roots);
    } on Object {
      return null;
    }
  }
}

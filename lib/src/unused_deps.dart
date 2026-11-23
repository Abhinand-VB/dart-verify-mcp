import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'dart_source.dart';
import 'files.dart';
import 'pubspec.dart';

/// How a declared dependency with no `package:` import was classified.
enum DepStatus {
  /// No import, and nothing else this tool knows to look for. A candidate for
  /// removal, not a verdict.
  unusedCandidate('unused_candidate'),

  /// No import, but a known mechanism (fonts, builders, native code, pubspec
  /// config, executables) explains why it may still be needed.
  likelyNeeded('likely_needed'),

  /// Listed in `unused_dependencies.allow` in verify_gate.yaml.
  allowlisted('allowlisted');

  const DepStatus(this.id);
  final String id;
}

class DepFinding {
  DepFinding({
    required this.name,
    required this.section,
    required this.status,
    required this.reason,
    this.evidence = const [],
    this.isPlugin = false,
  });

  final String name;

  /// `dependencies` or `dev_dependencies`.
  final String section;
  final DepStatus status;
  final String reason;
  final List<String> evidence;
  final bool isPlugin;

  Map<String, Object?> toJson() => {
    'name': name,
    'section': section,
    'status': status.id,
    'reason': reason,
    if (evidence.isNotEmpty) 'evidence': evidence,
    if (isPlugin) 'flutter_plugin': true,
  };
}

class PackageDepReport {
  PackageDepReport({
    required this.name,
    required this.dir,
    required this.filesScanned,
    required this.declared,
    required this.used,
    required this.findings,
    required this.packageConfigFound,
  });

  final String name;

  /// Relative to the project root ('.' for the root package).
  final String dir;
  final int filesScanned;
  final int declared;

  /// Dependency name to the first place it is used.
  final Map<String, String> used;
  final List<DepFinding> findings;
  final bool packageConfigFound;

  Iterable<DepFinding> withStatus(DepStatus s) =>
      findings.where((f) => f.status == s);

  Map<String, Object?> toJson() => {
    'package': name,
    'dir': dir,
    'files_scanned': filesScanned,
    'declared_checked': declared,
    'used_count': used.length,
    'unused_candidates': [
      for (final f in withStatus(DepStatus.unusedCandidate)) f.toJson(),
    ],
    'likely_needed': [
      for (final f in withStatus(DepStatus.likelyNeeded)) f.toJson(),
    ],
    'allowlisted': [
      for (final f in withStatus(DepStatus.allowlisted)) f.toJson(),
    ],
    if (!packageConfigFound)
      'warning':
          'No .dart_tool/package_config.json found; run pub get so plugin, '
          'builder and asset packages can be recognised.',
  };
}

class UnusedDepsReport {
  UnusedDepsReport(this.packages, {required this.includeDev});

  final List<PackageDepReport> packages;
  final bool includeDev;

  int get candidateCount => packages.fold(
    0,
    (n, pkg) => n + pkg.withStatus(DepStatus.unusedCandidate).length,
  );

  Map<String, Object?> toJson() => {
    'candidate_count': candidateCount,
    'include_dev': includeDev,
    'packages': [for (final pkg in packages) pkg.toJson()],
    'caveat':
        'A candidate has no package: import or export in this package and '
        'none of the other usage signals this tool checks. That is evidence, '
        'not proof: verify each one before removing it.',
  };

  String summary() {
    final b = StringBuffer(
      'unused_dependencies: $candidateCount candidate(s) across '
      '${packages.length} package(s)'
      '${includeDev ? ' (dev_dependencies included)' : ''}.',
    );
    for (final pkg in packages) {
      final c = pkg.withStatus(DepStatus.unusedCandidate).toList();
      final l = pkg.withStatus(DepStatus.likelyNeeded).toList();
      if (c.isEmpty && l.isEmpty) continue;
      b.write('\n  ${pkg.name} (${pkg.dir}):');
      for (final f in c) {
        b.write('\n    candidate: ${f.name}${f.isPlugin ? ' (plugin)' : ''}');
      }
      for (final f in l) {
        b.write('\n    likely needed: ${f.name}: ${f.reason}');
      }
    }
    if (candidateCount > 0) {
      b.write('\n  Candidates are not proof. Verify each before removing.');
    }
    return b.toString();
  }
}

/// Packages known to be used without an import, keyed by name, for when the
/// package source cannot be inspected (no `pub get` yet).
const _knownByName = <String, String>{
  'cupertino_icons': 'icon font used through CupertinoIcons in Flutter itself',
  'build_runner': 'runs code generation (dart run build_runner)',
  'flutter_launcher_icons': 'command-line tool configured in pubspec.yaml',
  'flutter_native_splash': 'command-line tool configured in pubspec.yaml',
};

/// pubspec top-level sections that configure a tool under another name.
const _configSectionAliases = <String, String>{
  'flutter_icons': 'flutter_launcher_icons',
  'msix_config': 'msix',
  'flutter_gen': 'flutter_gen_runner',
};

/// Finds declared dependencies with no `package:<name>/` import or export.
///
/// Every package under [projectRoot] is checked against its own sources;
/// nested packages are excluded from their parent's scan.
UnusedDepsReport findUnusedDependencies(
  String projectRoot, {
  bool includeDev = false,
  Map<String, String> allow = const {},
  bool nested = true,
}) {
  final root = p.normalize(p.absolute(projectRoot));
  final packageDirs = nested
      ? findPackageDirs(root)
      : [if (File(p.join(root, 'pubspec.yaml')).existsSync()) root];
  final reports = <PackageDepReport>[];
  for (final dir in packageDirs) {
    final others = {
      for (final d in packageDirs)
        if (d != dir && p.isWithin(dir, d)) d,
    };
    reports.add(
      _checkPackage(
        root,
        dir,
        stopAt: others,
        includeDev: includeDev,
        allow: allow,
      ),
    );
  }
  return UnusedDepsReport(reports, includeDev: includeDev);
}

PackageDepReport _checkPackage(
  String root,
  String dir, {
  required Set<String> stopAt,
  required bool includeDev,
  required Map<String, String> allow,
}) {
  final pubspec = Pubspec.load(dir);
  final declared = <String, String>{
    for (final n in pubspec.dependencies.keys) n: 'dependencies',
    if (includeDev)
      for (final n in pubspec.devDependencies.keys)
        if (!pubspec.dependencies.containsKey(n)) n: 'dev_dependencies',
  };

  final used = <String, String>{};
  final files = dartFilesUnder(dir, stopAt: stopAt);
  for (final f in files) {
    String text;
    try {
      text = f.readAsStringSync();
    } on FileSystemException {
      continue;
    }
    for (final d in parseDirectives(text)) {
      final name = packageNameOf(d.uri);
      if (name == null || !declared.containsKey(name)) continue;
      used.putIfAbsent(name, () => '${relPosix(root, f.path)}:${d.line}');
    }
  }

  // analysis_options.yaml `include: package:x/...` is a real use: removing x
  // breaks analysis.
  for (final f in listFiles(
    dir,
    accept: (n) => n.startsWith('analysis_options') && n.endsWith('.yaml'),
    stopAt: stopAt,
  )) {
    final lines = f.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      for (final m in RegExp(
        r'package:([a-zA-Z0-9_]+)/',
      ).allMatches(lines[i])) {
        final name = m.group(1)!;
        if (!declared.containsKey(name)) continue;
        used.putIfAbsent(name, () => '${relPosix(root, f.path)}:${i + 1}');
      }
    }
  }

  final config = PackageConfig.find(dir);
  final buildYaml = File(p.join(dir, 'build.yaml'));
  final buildYamlText = buildYaml.existsSync()
      ? buildYaml.readAsStringSync()
      : '';
  _NativeIndex? nativeIndex;

  final findings = <DepFinding>[];
  for (final entry in declared.entries) {
    final name = entry.key;
    final section = entry.value;
    if (used.containsKey(name)) continue;

    DepFinding finding(
      DepStatus status,
      String reason, {
      List<String> evidence = const [],
      bool plugin = false,
    }) => DepFinding(
      name: name,
      section: section,
      status: status,
      reason: reason,
      evidence: evidence,
      isPlugin: plugin,
    );

    if (allow.containsKey(name)) {
      findings.add(finding(DepStatus.allowlisted, allow[name]!));
      continue;
    }

    final configKey = pubspec.topLevelKeys.contains(name)
        ? name
        : _configSectionAliases.entries
              .where(
                (e) => e.value == name && pubspec.topLevelKeys.contains(e.key),
              )
              .map((e) => e.key)
              .firstOrNull;
    if (configKey != null) {
      findings.add(
        finding(
          DepStatus.likelyNeeded,
          'configured by the top-level `$configKey:` section of pubspec.yaml',
        ),
      );
      continue;
    }

    if (buildYamlText.isNotEmpty &&
        RegExp('\\b${RegExp.escape(name)}\\b').hasMatch(buildYamlText)) {
      findings.add(
        finding(DepStatus.likelyNeeded, 'referenced from build.yaml'),
      );
      continue;
    }

    final spec = pubspec.dependencies[name] ?? pubspec.devDependencies[name];
    final pkgRoot = config?.roots[name];
    if (pkgRoot == null) {
      final known = _knownByName[name] ?? _nameHeuristic(name, section);
      findings.add(
        known != null
            ? finding(DepStatus.likelyNeeded, '$known (judged by name only)')
            : finding(
                DepStatus.unusedCandidate,
                Pubspec.isSdkDependency(spec)
                    ? 'SDK package with no import'
                    : 'no package: import or export found; package source '
                          'could not be inspected (run pub get)',
              ),
      );
      continue;
    }

    final info = _PackageInfo.read(pkgRoot);
    if (info == null) {
      findings.add(
        finding(
          DepStatus.unusedCandidate,
          'no package: import or export found',
        ),
      );
      continue;
    }

    if (name == 'build_runner') {
      findings.add(finding(DepStatus.likelyNeeded, _knownByName[name]!));
      continue;
    }
    if (info.hasBuilders) {
      findings.add(
        finding(
          DepStatus.likelyNeeded,
          'provides build_runner builders (its build.yaml declares builders)',
        ),
      );
      continue;
    }
    if (!info.hasLibDart && info.shipsFontsOrAssets) {
      findings.add(
        finding(
          DepStatus.likelyNeeded,
          'ships fonts or assets and has no Dart library, so it is never '
          'imported',
        ),
      );
      continue;
    }
    if (info.implementsPackage != null) {
      findings.add(
        finding(
          DepStatus.likelyNeeded,
          'platform implementation of ${info.implementsPackage}; used through '
          "that package's API",
          plugin: true,
        ),
      );
      continue;
    }
    if (info.isFfiPlugin) {
      findings.add(
        finding(
          DepStatus.likelyNeeded,
          'FFI plugin that bundles native code, which may be loaded at '
          'runtime without a Dart import',
          plugin: true,
        ),
      );
      continue;
    }
    if (info.isPlugin) {
      nativeIndex ??= _NativeIndex.build(dir, root);
      final hits = nativeIndex.find([name, ...info.nativeIdentifiers]);
      if (hits.isNotEmpty) {
        findings.add(
          finding(
            DepStatus.likelyNeeded,
            'Flutter plugin referenced from native code',
            evidence: hits,
            plugin: true,
          ),
        );
      } else {
        findings.add(
          finding(
            DepStatus.unusedCandidate,
            'Flutter plugin with no Dart import, and none of its native '
            'identifiers (${[name, ...info.nativeIdentifiers].join(', ')}) '
            'appear in native sources outside generated plugin registrants. '
            'Registration in GeneratedPluginRegistrant happens for every '
            'declared plugin and is not evidence of use.',
            plugin: true,
          ),
        );
      }
      continue;
    }
    if (section == 'dev_dependencies' && info.hasExecutables) {
      findings.add(
        finding(
          DepStatus.likelyNeeded,
          'provides executables (dart run $name); check scripts and CI',
        ),
      );
      continue;
    }
    findings.add(
      finding(
        DepStatus.unusedCandidate,
        info.hasExecutables
            ? 'no package: import or export found; it does provide '
                  'executables, so check scripts and CI for `dart run $name`'
            : 'no package: import or export found',
      ),
    );
  }

  findings.sort((a, b) => a.name.compareTo(b.name));
  return PackageDepReport(
    name: pubspec.name,
    dir: relPosix(root, dir).isEmpty ? '.' : relPosix(root, dir),
    filesScanned: files.length,
    declared: declared.length,
    used: used,
    findings: findings,
    packageConfigFound: config != null,
  );
}

String? _nameHeuristic(String name, String section) {
  if (section != 'dev_dependencies') return null;
  if (name.endsWith('_generator') || name.endsWith('_builder')) {
    return 'looks like a build_runner generator';
  }
  return null;
}

/// What this tool reads from a resolved dependency's own pubspec.
class _PackageInfo {
  _PackageInfo({
    required this.isPlugin,
    required this.isFfiPlugin,
    required this.implementsPackage,
    required this.nativeIdentifiers,
    required this.hasBuilders,
    required this.hasLibDart,
    required this.shipsFontsOrAssets,
    required this.hasExecutables,
  });

  final bool isPlugin;
  final bool isFfiPlugin;
  final String? implementsPackage;
  final List<String> nativeIdentifiers;
  final bool hasBuilders;
  final bool hasLibDart;
  final bool shipsFontsOrAssets;
  final bool hasExecutables;

  static _PackageInfo? read(String dir) {
    final pubspecFile = File(p.join(dir, 'pubspec.yaml'));
    if (!pubspecFile.existsSync()) return null;
    Object? doc;
    try {
      doc = loadYaml(pubspecFile.readAsStringSync());
    } on Object {
      return null;
    }
    if (doc is! Map) return null;
    final flutter = doc['flutter'];
    final plugin = flutter is Map ? flutter['plugin'] : null;
    var ffi = false;
    final ids = <String>{};
    String? implementsPackage;
    if (plugin is Map) {
      if (plugin['implements'] is String) {
        implementsPackage = plugin['implements'] as String;
      }
      final platforms = plugin['platforms'];
      if (platforms is Map) {
        for (final platform in platforms.values) {
          if (platform is! Map) continue;
          if (platform['ffiPlugin'] == true) ffi = true;
          for (final key in ['package', 'pluginClass']) {
            final v = platform[key];
            if (v is String && v.isNotEmpty && v != 'none') ids.add(v);
          }
        }
      }
    }
    final libDir = Directory(p.join(dir, 'lib'));
    final hasLibDart =
        libDir.existsSync() &&
        libDir.listSync(recursive: true).any((e) => e.path.endsWith('.dart'));
    var hasBuilders = false;
    final build = File(p.join(dir, 'build.yaml'));
    if (build.existsSync()) {
      try {
        final b = loadYaml(build.readAsStringSync());
        hasBuilders =
            b is Map &&
            (b['builders'] is Map || b['post_process_builders'] is Map);
      } on Object {
        hasBuilders = false;
      }
    }
    final executables = doc['executables'];
    final binDir = Directory(p.join(dir, 'bin'));
    final hasExecutables =
        (executables is Map && executables.isNotEmpty) ||
        (binDir.existsSync() &&
            binDir.listSync().any((e) => e.path.endsWith('.dart')));
    return _PackageInfo(
      isPlugin: plugin is Map,
      isFfiPlugin: ffi,
      implementsPackage: implementsPackage,
      nativeIdentifiers: ids.toList()..sort(),
      hasBuilders: hasBuilders,
      hasLibDart: hasLibDart,
      shipsFontsOrAssets:
          flutter is Map &&
          (flutter['fonts'] != null || flutter['assets'] != null),
      hasExecutables: hasExecutables,
    );
  }
}

/// The app's own native sources, read once, for plugin-usage lookups.
class _NativeIndex {
  _NativeIndex(this._files);

  final List<(String, List<String>)> _files;

  static const _platformDirs = ['android', 'ios', 'macos', 'windows', 'linux'];
  static const _extensions = [
    '.kt',
    '.kts',
    '.java',
    '.swift',
    '.m',
    '.mm',
    '.h',
    '.c',
    '.cc',
    '.cpp',
    '.xml',
    '.gradle',
    '.plist',
    '.txt',
  ];

  static bool _generated(String name) {
    final lower = name.toLowerCase();
    return lower.startsWith('generatedpluginregistrant') ||
        lower.startsWith('generated_plugin_registrant') ||
        lower.startsWith('generated_plugins');
  }

  static _NativeIndex build(String packageDir, String root) {
    final files = <(String, List<String>)>[];
    for (final platform in _platformDirs) {
      for (final f in listFiles(
        p.join(packageDir, platform),
        accept: (n) =>
            !_generated(n) &&
            (n == 'Podfile' || _extensions.any((e) => n.endsWith(e))),
      )) {
        // ios/Flutter, windows/flutter and linux/flutter hold tool-generated
        // config, not app code.
        final rel = relPosix(packageDir, f.path).toLowerCase();
        if (rel.contains('/flutter/')) continue;
        try {
          files.add((relPosix(root, f.path), f.readAsLinesSync()));
        } on FileSystemException {
          continue;
        } on FormatException {
          continue;
        }
      }
    }
    return _NativeIndex(files);
  }

  List<String> find(List<String> needles) {
    final hits = <String>[];
    for (final (path, lines) in _files) {
      for (var i = 0; i < lines.length; i++) {
        if (needles.any(lines[i].contains)) {
          hits.add('$path:${i + 1}');
          if (hits.length >= 5) return hits;
        }
      }
    }
    return hits;
  }
}

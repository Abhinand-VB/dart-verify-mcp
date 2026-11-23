import 'dart:io';

import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

import 'config.dart';
import 'dart_source.dart';
import 'files.dart';
import 'pubspec.dart';

/// One broken rule at one place.
class LayerViolation {
  LayerViolation({
    required this.rule,
    required this.file,
    required this.line,
    required this.kind,
    required this.detail,
    required this.source,
    this.uri,
    this.resolvedUri,
    this.matched,
    this.reason,
  });

  final String rule;

  /// Relative to the project root, forward slashes.
  final String file;
  final int line;

  /// `import`, `export`, or `code` for a forbid_code match.
  final String kind;
  final String? uri;

  /// For a relative import, the `package:` URI it resolves to (if it lands in
  /// some package's lib/).
  final String? resolvedUri;

  /// The forbid pattern that matched, or null for an allowlist miss.
  final String? matched;
  final String detail;
  final String? reason;

  /// The offending source line, trimmed.
  final String source;

  Map<String, Object?> toJson() => {
    'rule': rule,
    'file': file,
    'line': line,
    'kind': kind,
    if (uri != null) 'uri': uri,
    if (resolvedUri != null) 'resolved_uri': resolvedUri,
    if (matched != null) 'matched': matched,
    'detail': detail,
    if (reason != null) 'reason': reason,
    'source': source,
  };
}

class LayerReport {
  LayerReport({
    required this.violations,
    required this.filesChecked,
    required this.rules,
    this.configSource,
  });

  final List<LayerViolation> violations;

  /// Rule name to the number of files it applied to. A rule that matched no
  /// files is reported, because a typo in a glob otherwise looks exactly like
  /// a clean codebase.
  final Map<String, int> filesChecked;
  final List<String> rules;
  final String? configSource;

  bool get passed => violations.isEmpty;

  List<String> get rulesMatchingNoFiles => [
    for (final r in rules)
      if ((filesChecked[r] ?? 0) == 0) r,
  ];

  Map<String, Object?> toJson() => {
    'passed': passed,
    'violation_count': violations.length,
    'rules': [
      for (final r in rules) {'name': r, 'files_checked': filesChecked[r] ?? 0},
    ],
    if (rulesMatchingNoFiles.isNotEmpty)
      'warnings': [
        for (final r in rulesMatchingNoFiles)
          'Rule "$r" matched no files. Check its `paths` globs.',
      ],
    'violations': [for (final v in violations) v.toJson()],
    if (configSource != null) 'config': configSource,
  };

  String summary() {
    if (rules.isEmpty) {
      return 'check_layers: no layers configured in $configFileName, nothing '
          'checked.';
    }
    final b = StringBuffer();
    if (passed) {
      b.write(
        'check_layers: OK. ${rules.length} rule(s) hold across '
        '${filesChecked.values.fold(0, (a, n) => a + n)} file check(s).',
      );
    } else {
      b.writeln('check_layers: ${violations.length} violation(s).');
      for (final v in violations.take(20)) {
        b.writeln('  ${v.file}:${v.line} [${v.rule}] ${v.detail}');
      }
      if (violations.length > 20) {
        b.writeln('  ... and ${violations.length - 20} more (see JSON).');
      }
    }
    for (final r in rulesMatchingNoFiles) {
      b.write('\n  warning: rule "$r" matched no files.');
    }
    return b.toString().trimRight();
  }
}

/// True if [uri] matches [pattern].
///
/// A pattern matches its exact text, or a prefix of the URI that ends at a
/// path boundary: `package:flutter/` and `package:flutter` both match
/// `package:flutter/material.dart` but neither matches
/// `package:flutter_riverpod/flutter_riverpod.dart`. A `*` matches any run of
/// characters other than `/`.
bool uriMatches(String pattern, String uri) {
  if (pattern.contains('*')) {
    final re = RegExp(
      '^${pattern.split('*').map(RegExp.escape).join('[^/]*')}',
    );
    final m = re.firstMatch(uri);
    if (m == null) return false;
    return m.end == uri.length ||
        pattern.endsWith('/') ||
        pattern.endsWith(':') ||
        uri[m.end] == '/';
  }
  if (uri == pattern) return true;
  if (!uri.startsWith(pattern)) return false;
  if (pattern.endsWith('/') || pattern.endsWith(':')) return true;
  return uri[pattern.length] == '/';
}

Glob _glob(String pattern) {
  var pat = pattern.replaceAll(r'\', '/');
  if (pat.startsWith('./')) pat = pat.substring(2);
  // A bare directory such as `lib/ui` means everything beneath it.
  if (!pat.contains(RegExp(r'[*?\[{]')) && !pat.endsWith('.dart')) {
    pat = pat.endsWith('/') ? '$pat**' : '$pat/**';
  }
  return Glob(pat, context: p.posix);
}

/// Checks every rule in [rules] against the Dart files under [projectRoot].
LayerReport checkLayers(
  String projectRoot,
  List<LayerRule> rules, {
  String? configSource,
}) {
  final root = p.normalize(p.absolute(projectRoot));
  final all = dartFilesUnder(root);
  final rel = {for (final f in all) f.path: relPosix(root, f.path)};
  final violations = <LayerViolation>[];
  final filesChecked = <String, int>{};
  final pkgCache = <String, Pubspec?>{};
  final textCache = <String, String>{};
  final directiveCache = <String, List<DirectiveUri>>{};

  Pubspec? packageFor(String fileAbs) {
    final dir = nearestPackageDir(fileAbs, limit: root);
    if (dir == null) return null;
    return pkgCache.putIfAbsent(dir, () {
      try {
        return Pubspec.load(dir);
      } on Object {
        return null;
      }
    });
  }

  String? canonical(String fileAbs, String uri) {
    if (uri.contains(':')) return null;
    final target = p.normalize(p.join(p.dirname(fileAbs), uri));
    final dir = nearestPackageDir(target, limit: root);
    if (dir == null) return null;
    final lib = p.join(dir, 'lib');
    if (!p.isWithin(lib, target)) return null;
    final name = packageFor(target)?.name;
    if (name == null) return null;
    return 'package:$name/${relPosix(lib, target)}';
  }

  for (final rule in rules) {
    final includes = rule.paths.map(_glob).toList();
    final excludes = rule.exclude.map(_glob).toList();
    var count = 0;
    for (final file in all) {
      final path = rel[file.path]!;
      if (!includes.any((g) => g.matches(path))) continue;
      if (excludes.any((g) => g.matches(path))) continue;
      count++;
      final text = textCache.putIfAbsent(file.path, () {
        try {
          return file.readAsStringSync();
        } on FileSystemException {
          return '';
        }
      });
      final lines = text.split('\n');
      String lineText(int n) => n - 1 < lines.length ? lines[n - 1].trim() : '';

      final directives = directiveCache.putIfAbsent(
        file.path,
        () => parseDirectives(text),
      );
      for (final d in directives) {
        if (d.kind == DirectiveKind.part) continue;
        final resolved = canonical(file.path, d.uri);
        final candidates = [d.uri, ?resolved];
        String? hit;
        for (final f in rule.forbid) {
          if (candidates.any((c) => uriMatches(f, c))) {
            hit = f;
            break;
          }
        }
        final cond = d.condition == null ? '' : ' (if ${d.condition})';
        if (hit != null) {
          violations.add(
            LayerViolation(
              rule: rule.name,
              file: path,
              line: d.line,
              kind: d.kind.name,
              uri: d.uri,
              resolvedUri: resolved,
              matched: hit,
              detail:
                  '${d.kind.name}s "${d.uri}"$cond'
                  '${resolved == null ? '' : ' (= $resolved)'}, which matches '
                  'forbidden "$hit".',
              reason: rule.reason,
              source: lineText(d.line),
            ),
          );
          continue;
        }
        final allow = rule.allow;
        if (allow != null &&
            d.uri.contains(':') &&
            !allow.any((a) => uriMatches(a, d.uri))) {
          violations.add(
            LayerViolation(
              rule: rule.name,
              file: path,
              line: d.line,
              kind: d.kind.name,
              uri: d.uri,
              detail:
                  '${d.kind.name}s "${d.uri}"$cond, which is not in the '
                  'allow list.',
              reason: rule.reason,
              source: lineText(d.line),
            ),
          );
        }
      }

      if (rule.forbidCode.isNotEmpty) {
        final code = stripComments(text).split('\n');
        for (var i = 0; i < code.length; i++) {
          for (final c in rule.forbidCode) {
            if (!c.regex.hasMatch(code[i])) continue;
            violations.add(
              LayerViolation(
                rule: rule.name,
                file: path,
                line: i + 1,
                kind: 'code',
                matched: c.pattern,
                detail: 'code matches forbidden pattern /${c.pattern}/.',
                reason: rule.reason,
                source: lineText(i + 1),
              ),
            );
            break;
          }
        }
      }
    }
    filesChecked[rule.name] = count;
  }

  violations.sort((a, b) {
    final f = a.file.compareTo(b.file);
    return f != 0 ? f : a.line.compareTo(b.line);
  });
  return LayerReport(
    violations: violations,
    filesChecked: filesChecked,
    rules: [for (final r in rules) r.name],
    configSource: configSource,
  );
}

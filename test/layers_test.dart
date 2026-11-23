import 'package:dart_verify_mcp/dart_verify_mcp.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  group('uriMatches', () {
    test('matches at path boundaries only', () {
      expect(
        uriMatches('package:flutter/', 'package:flutter/material.dart'),
        isTrue,
      );
      expect(
        uriMatches('package:flutter', 'package:flutter/material.dart'),
        isTrue,
      );
      expect(
        uriMatches('package:flutter', 'package:flutter_riverpod/x.dart'),
        isFalse,
      );
      expect(
        uriMatches('package:flutter/', 'package:flutter_test/x.dart'),
        isFalse,
      );
      expect(uriMatches('dart:io', 'dart:io'), isTrue);
      expect(uriMatches('dart:', 'dart:isolate'), isTrue);
      expect(uriMatches('dart:io', 'dart:isolate'), isFalse);
    });

    test('supports * within one path segment', () {
      expect(uriMatches('package:*/src/', 'package:other/src/a.dart'), isTrue);
      expect(uriMatches('package:*/src/', 'package:other/a.dart'), isFalse);
      expect(
        uriMatches('package:app/*/internal/', 'package:app/a/internal/x.dart'),
        isTrue,
      );
    });
  });

  group('checkLayers', () {
    late String root;

    setUp(() {
      root = tempDir();
      writeFiles(root, {
        'pubspec.yaml': 'name: app\n',
        'lib/ui/screen.dart': "import 'package:flutter/widgets.dart';\n",
        'lib/domain/model.dart': '''
import 'package:meta/meta.dart';
// import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../ui/screen.dart';
''',
        'lib/domain/clock.dart': '''
/// Never call DateTime.now() here.
final t = DateTime.now();
final s = 'DateTime.now() in a string is still code';
''',
        'lib/domain/clock.g.dart': 'final t = DateTime.now();\n',
        'packages/core/pubspec.yaml': 'name: core\n',
        'packages/core/lib/core.dart': '''
import 'dart:async';
import 'package:meta/meta.dart';
import 'src/helper.dart';
import 'stub.dart'
    if (dart.library.io) 'dart:io';
''',
        'packages/core/lib/src/helper.dart': '',
        'packages/core/lib/stub.dart': '',
      });
    });

    test('reports allowlist misses, relative imports, and code patterns', () {
      final report = checkLayers(root, [
        LayerRule(
          name: 'A core purity',
          paths: ['packages/core/lib'],
          allow: ['dart:async', 'package:meta/', 'package:core/'],
          reason: 'the core runs under plain dart test',
        ),
        LayerRule(
          name: 'domain does not reach into ui or flutter',
          paths: ['lib/domain/**.dart'],
          forbid: ['package:flutter/', 'package:app/ui/'],
        ),
        LayerRule(
          name: 'B no ambient time',
          paths: ['lib/**'],
          exclude: ['**.g.dart'],
          forbidCode: [CodePattern(r'DateTime\s*\.\s*now\s*\(')],
        ),
      ]);

      final found = [
        for (final v in report.violations) (v.rule, v.file, v.line, v.kind),
      ];
      expect(found, [
        ('B no ambient time', 'lib/domain/clock.dart', 2, 'code'),
        ('B no ambient time', 'lib/domain/clock.dart', 3, 'code'),
        (
          'domain does not reach into ui or flutter',
          'lib/domain/model.dart',
          4,
          'import',
        ),
        ('A core purity', 'packages/core/lib/core.dart', 5, 'import'),
      ]);
      final relative = report.violations[2];
      expect(relative.uri, '../ui/screen.dart');
      expect(relative.resolvedUri, 'package:app/ui/screen.dart');
      expect(relative.matched, 'package:app/ui/');
      final conditional = report.violations[3];
      expect(conditional.uri, 'dart:io');
      expect(conditional.detail, contains('dart.library.io'));
      expect(conditional.reason, 'the core runs under plain dart test');
      expect(report.passed, isFalse);
      expect(report.filesChecked['A core purity'], 3);
      expect(report.summary(), contains('4 violation(s)'));
    });

    test('passes when rules hold, and flags rules that match no files', () {
      final report = checkLayers(root, [
        LayerRule(name: 'ui only', paths: ['lib/ui'], forbid: ['dart:io']),
        LayerRule(name: 'typo', paths: ['lib/uii/**'], forbid: ['dart:io']),
      ]);
      expect(report.passed, isTrue);
      expect(report.rulesMatchingNoFiles, ['typo']);
      expect(report.toJson()['warnings'], hasLength(1));
    });

    test('with no rules, says so rather than claiming success', () {
      final report = checkLayers(root, const []);
      expect(report.summary(), contains('nothing checked'));
      expect(report.toJson()['passed'], isNull);
    });
  });
}

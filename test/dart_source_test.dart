import 'package:dart_verify_mcp/dart_verify_mcp.dart';
import 'package:test/test.dart';

List<String> uris(String source) => [
  for (final d in parseDirectives(source)) d.uri,
];

void main() {
  group('parseDirectives', () {
    test('reads plain imports and exports with line numbers', () {
      final d = parseDirectives('''
library;

import 'dart:io';
export "package:a/a.dart";
''');
      expect(d.map((x) => (x.kind, x.uri, x.line)), [
        (DirectiveKind.import, 'dart:io', 3),
        (DirectiveKind.export, 'package:a/a.dart', 4),
      ]);
    });

    test('ignores imports inside line, block and nested block comments', () {
      expect(
        uris('''
// import 'dart:io';
/* import 'dart:html'; */
/* outer /* inner import 'dart:ffi'; */ still comment import 'dart:isolate'; */
/// import 'package:doc/comment.dart';
import 'dart:math';
'''),
        ['dart:math'],
      );
    });

    test('ignores import-shaped text inside strings', () {
      expect(
        uris(r"""
import 'dart:core';
const a = "import 'dart:io';";
const b = '''
import 'package:flutter/material.dart';
''';
const c = r'import "dart:ffi";';
final d = 'x ${"import 'dart:html';"} y';
"""),
        ['dart:core'],
      );
    });

    test('handles a directive split across lines with show/hide/as', () {
      final d = parseDirectives('''
import
    'package:flutter/widgets.dart'
    as w
    show
        Widget,
        StatelessWidget;
export 'src/a.dart' hide B;
''');
      expect(d.map((x) => (x.uri, x.line, x.directiveLine)), [
        ('package:flutter/widgets.dart', 2, 1),
        ('src/a.dart', 7, 7),
      ]);
    });

    test('reports every URI of a conditional import', () {
      final d = parseDirectives('''
import 'stub.dart'
    if (dart.library.io) 'io_impl.dart'
    if (dart.library.js_interop) 'web_impl.dart';
export 'a.dart' if (dart.library.ui == 'true') 'package:flutter/b.dart';
''');
      expect(d.map((x) => (x.uri, x.condition)), [
        ('stub.dart', null),
        ('io_impl.dart', 'dart.library.io'),
        ('web_impl.dart', 'dart.library.js_interop'),
        ('a.dart', null),
        ('package:flutter/b.dart', "dart.library.ui == 'true'"),
      ]);
      expect(d[1].line, 2);
    });

    test('reads part directives but not part of', () {
      final d = parseDirectives('''
part 'a.g.dart';
part of 'lib.dart';
''');
      expect(d.map((x) => (x.kind, x.uri)), [(DirectiveKind.part, 'a.g.dart')]);
    });

    test('handles deferred imports and annotations', () {
      expect(
        uris('''
@Deprecated('old')
import 'package:a/a.dart' deferred as a;
import 'package:b/b.dart';
'''),
        ['package:a/a.dart', 'package:b/b.dart'],
      );
    });

    test('does not treat identifiers named import as directives', () {
      expect(
        uris('''
void f() {
  final import = 1;
  final part = import + 1;
  config.import('x');
  print(part);
}
'''),
        isEmpty,
      );
    });

    test('keeps line numbers right after multi-line strings and comments', () {
      final d = parseDirectives('''
/*
 * header
 */
const s = """
a
b
""";
import 'dart:io';
''');
      expect(d.single.line, 8);
    });

    test('survives unterminated strings without throwing', () {
      expect(
        () => parseDirectives("import 'dart:io\nimport 'x.dart';"),
        returnsNormally,
      );
    });
  });

  group('stripComments', () {
    test('removes comments, keeps strings and line count', () {
      const src = '''
a(); // DateTime.now()
/* DateTime.now()
   more */ b('// not a comment');
''';
      final out = stripComments(src);
      expect(out.split('\n').length, src.split('\n').length);
      expect(out, isNot(contains('DateTime')));
      expect(out, contains("'// not a comment'"));
      expect(out.split('\n')[2], contains('b('));
    });
  });

  test('packageNameOf', () {
    expect(packageNameOf('package:flutter/material.dart'), 'flutter');
    expect(packageNameOf('package:a_b/src/x.dart'), 'a_b');
    expect(packageNameOf('dart:io'), isNull);
    expect(packageNameOf('src/a.dart'), isNull);
    expect(packageNameOf('package:broken'), isNull);
  });
}

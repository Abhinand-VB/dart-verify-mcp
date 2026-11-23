@Tags(['slow'])
library;

import 'dart:io';

import 'package:dart_verify_mcp/dart_verify_mcp.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fixtures.dart';

String git(String repo, List<String> args) {
  final r = Process.runSync('git', [
    '-c',
    'user.name=fixture',
    '-c',
    'user.email=fixture@example.invalid',
    '-c',
    'commit.gpgsign=false',
    ...args,
  ], workingDirectory: repo);
  if (r.exitCode != 0) {
    fail('git ${args.join(' ')} failed: ${r.stdout}\n${r.stderr}');
  }
  return '${r.stdout}';
}

/// A tiny package with a bug at the base commit and the fix plus new tests
/// in the working tree.
String buildFixture() {
  final repo = tempDir('dvm_prove_');
  writeFiles(repo, {
    'pubspec.yaml': '''
name: fixture
publish_to: none
environment:
  sdk: ^3.5.0
dev_dependencies:
  test: any
''',
    '.gitignore': '.dart_tool/\n',
    // The bug: negatives pass straight through.
    'lib/calc.dart': 'int clampToZero(int x) => x;\n',
    'test/existing_test.dart': '''
import 'package:fixture/calc.dart';
import 'package:test/test.dart';

void main() {
  test('zero stays zero', () => expect(clampToZero(0), 0));
}
''',
  });
  git(repo, ['init', '-q', '-b', 'main']);
  git(repo, ['add', '.']);
  git(repo, ['commit', '-q', '-m', 'base']);

  writeFiles(repo, {
    // The fix, plus a function that did not exist at base.
    'lib/calc.dart': '''
int clampToZero(int x) => x < 0 ? 0 : x;
int twice(int x) => 2 * x;
''',
    // A new test-side helper the new test depends on: it has to be carried
    // onto base with the test, or the test cannot compile there.
    'test/support/expectations.dart': '''
import 'package:test/test.dart';

void expectZero(int v) => expect(v, 0);
''',
    'test/clamp_test.dart': '''
import 'package:fixture/calc.dart';
import 'package:test/test.dart';

import 'support/expectations.dart';

void main() {
  test('clamps negatives', () => expectZero(clampToZero(-5)));
  test('keeps positives', () => expect(clampToZero(3), 3));
}
''',
    'test/twice_test.dart': '''
import 'package:fixture/calc.dart';
import 'package:test/test.dart';

void main() {
  test('doubles', () => expect(twice(4), 8));
}
''',
    'test/broken_test.dart': '''
import 'package:fixture/calc.dart';
import 'package:test/test.dart';

void main() {
  test('wrong expectation', () => expect(clampToZero(-1), -1));
}
''',
  });
  return repo;
}

Map<String, Verdict> verdicts(ProveTestsReport r) => {
  for (final f in r.files)
    for (final t in f.verdicts) '${f.file}: ${t.name}': t.verdict,
};

void main() {
  test('classifies new tests against the base commit without touching the '
      'working tree', () async {
    final repo = buildFixture();
    final statusBefore = git(repo, ['status', '--porcelain']);
    final calcBefore = File(p.join(repo, 'lib/calc.dart')).readAsStringSync();

    final report = await proveTestsCanFail(repo);

    expect(verdicts(report), {
      'test/broken_test.dart: wrong expectation': Verdict.failsOnCurrent,
      'test/clamp_test.dart: clamps negatives': Verdict.failsOnBase,
      'test/clamp_test.dart: keeps positives': Verdict.passesOnBase,
      'test/twice_test.dart: doubles': Verdict.error,
    });
    expect(report.carriedFiles, ['test/support/expectations.dart']);
    expect(report.allDetectChange, isFalse);
    expect(report.counts['PASSES_ON_BASE'], 1);
    expect(report.summary(), contains('PASSES_ON_BASE: test/clamp_test.dart'));
    final twice = report.files.singleWhere(
      (f) => f.file == 'test/twice_test.dart',
    );
    expect(twice.verdicts.single.detail, contains('twice'));

    // The user's checkout is exactly as it was, and no worktree is left.
    expect(git(repo, ['status', '--porcelain']), statusBefore);
    expect(File(p.join(repo, 'lib/calc.dart')).readAsStringSync(), calcBefore);
    expect(git(repo, ['worktree', 'list']).trim().split('\n'), hasLength(1));
  });

  test('checks named files against an older commit, base only', () async {
    final repo = buildFixture();
    git(repo, ['add', '.']);
    git(repo, ['commit', '-q', '-m', 'fix and tests']);

    final report = await proveTestsCanFail(
      repo,
      baseRef: 'HEAD~1',
      testFiles: ['test/clamp_test.dart'],
      checkCurrent: false,
    );
    expect(verdicts(report), {
      'test/clamp_test.dart: clamps negatives': Verdict.failsOnBase,
      'test/clamp_test.dart: keeps positives': Verdict.passesOnBase,
    });
    expect(report.checkCurrent, isFalse);
  });

  test('with nothing changed, says so', () async {
    final repo = buildFixture();
    git(repo, ['add', '.']);
    git(repo, ['commit', '-q', '-m', 'all in']);
    final report = await proveTestsCanFail(repo);
    expect(report.files, isEmpty);
    expect(report.summary(), contains('No new or modified'));
  });

  test(
    'outside a git repository, or with an unknown ref, it refuses',
    () async {
      final plain = tempDir();
      writeFiles(plain, {'pubspec.yaml': 'name: x\n'});
      // The system temp dir is assumed not to be inside a git repository.
      await expectLater(
        proveTestsCanFail(plain),
        throwsA(isA<ProveTestsException>()),
      );
      final repo = buildFixture();
      await expectLater(
        proveTestsCanFail(repo, baseRef: 'no-such-ref'),
        throwsA(isA<ProveTestsException>()),
      );
    },
  );
}

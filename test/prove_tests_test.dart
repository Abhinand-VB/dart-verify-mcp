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
    // An existing file gains one test. Only that test is judged: the old
    // one passing on old code says nothing about this change.
    'test/existing_test.dart': '''
import 'package:fixture/calc.dart';
import 'package:test/test.dart';

void main() {
  test('zero stays zero', () => expect(clampToZero(0), 0));

  test('clamps minus one', () {
    expect(clampToZero(-1), 0);
  });
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
    for (final t in f.verdicts)
      if (t.inDiff) '${f.file}: ${t.name}': t.verdict,
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
      'test/existing_test.dart: clamps minus one': Verdict.failsOnBase,
      'test/twice_test.dart: doubles': Verdict.error,
    });
    expect(report.unchangedCount, 1);
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

  test('handles a test in a nested pub workspace member', () async {
    final repo = tempDir('dvm_ws_');
    writeFiles(repo, {
      '.gitignore': '.dart_tool/\n',
      'pubspec.yaml': '''
name: ws_root
publish_to: none
environment:
  sdk: ^3.6.0
workspace:
  - pkgs/core
''',
      'pkgs/core/pubspec.yaml': '''
name: core
publish_to: none
environment:
  sdk: ^3.6.0
resolution: workspace
dev_dependencies:
  test: any
''',
      'pkgs/core/lib/core.dart': 'int one() => 0;\n',
    });
    git(repo, ['init', '-q', '-b', 'main']);
    git(repo, ['add', '.']);
    git(repo, ['commit', '-q', '-m', 'base']);
    writeFiles(repo, {
      'pkgs/core/lib/core.dart': 'int one() => 1;\n',
      'pkgs/core/test/one_test.dart': '''
import 'package:core/core.dart';
import 'package:test/test.dart';

void main() {
  test('one is one', () => expect(one(), 1));
}
''',
    });

    final report = await proveTestsCanFail(repo);
    expect(verdicts(report), {
      'pkgs/core/test/one_test.dart: one is one': Verdict.failsOnBase,
    });
    expect(report.files.single.packageDir, 'pkgs/core');
    expect(report.files.single.runner, 'dart');
  });

  test('reaches the same verdicts through a path spelled differently from '
      "git's", () async {
    // On macOS the temp dir is /var/... while git reports /private/var/...;
    // on Windows CI it is C:/Users/RUNNER~1/... while git reports the long
    // name. Reaching the repo through a link reproduces that mismatch on
    // any platform.
    final repo = buildFixture();
    final link = Link(p.join(tempDir('dvm_link_'), 'via_link'))
      ..createSync(repo);
    final report = await proveTestsCanFail(
      link.path,
      testFiles: ['test/clamp_test.dart'],
      checkCurrent: false,
    );
    expect(verdicts(report), {
      'test/clamp_test.dart: clamps negatives': Verdict.failsOnBase,
      'test/clamp_test.dart: keeps positives': Verdict.passesOnBase,
    });
    final auto = await proveTestsCanFail(link.path, checkCurrent: false);
    expect(auto.files.map((f) => f.file), contains('test/twice_test.dart'));
  });

  test(
    'an internal git or path failure is an error, never an empty result',
    () async {
      final repo = buildFixture();
      final elsewhere = tempDir('dvm_elsewhere_');

      // A runner that lies about one git command and passes the rest through.
      CommandRunner lying(String argument, ProcessOutcome Function() fake) =>
          (command, {required workingDirectory, required timeout}) async =>
              command.contains(argument)
              ? fake()
              : runCommand(
                  command,
                  workingDirectory: workingDirectory,
                  timeout: timeout,
                );
      ProcessOutcome outcome({required int code, String stdout = ''}) =>
          ProcessOutcome(
            command: const ['git'],
            workingDirectory: repo,
            exitCode: code,
            stdout: stdout,
            stderr: code == 0 ? '' : 'fatal: simulated',
            timedOut: false,
            duration: Duration.zero,
          );

      await expectLater(
        proveTestsCanFail(
          repo,
          runner: lying(
            '--show-toplevel',
            () => outcome(code: 0, stdout: '$elsewhere\n'),
          ),
        ),
        throwsA(
          isA<ProveTestsException>().having(
            (e) => e.message,
            'message',
            contains('Internal path mismatch'),
          ),
        ),
      );
      await expectLater(
        proveTestsCanFail(
          repo,
          runner: lying('ls-files', () => outcome(code: 128)),
        ),
        throwsA(isA<ProveTestsException>()),
      );
    },
  );

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

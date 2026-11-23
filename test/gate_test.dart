import 'dart:io';

import 'package:dart_verify_mcp/dart_verify_mcp.dart';
import 'package:dart_verify_mcp/src/gate.dart' show condenseProgress;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fixtures.dart';

/// A runner that records commands and fails the ones named in [failing].
class FakeRunner {
  FakeRunner({this.failing = const {}, this.timingOut = const {}});

  final Set<String> failing;
  final Set<String> timingOut;
  final calls = <(List<String>, String)>[];

  Future<ProcessOutcome> call(
    List<String> command, {
    required String workingDirectory,
    required Duration timeout,
  }) async {
    calls.add((command, workingDirectory));
    final line = command.join(' ');
    final timedOut = timingOut.any(line.contains);
    final failed = failing.any(line.contains);
    return ProcessOutcome(
      command: command,
      workingDirectory: workingDirectory,
      exitCode: timedOut ? null : (failed ? 1 : 0),
      stdout: failed ? 'error - lib/a.dart:1:1 - something' : 'ok',
      stderr: '',
      timedOut: timedOut,
      duration: const Duration(milliseconds: 5),
    );
  }
}

void main() {
  late String root;

  setUp(() {
    root = tempDir();
    writeFiles(root, {
      'pubspec.yaml': 'name: app\n',
      'lib/a.dart': '',
      'test/a_test.dart': '',
    });
  });

  test(
    'default steps check format without rewriting, then analyze and test',
    () async {
      final runner = FakeRunner();
      final report = await runGate(root, runner: runner.call);
      expect(report.done, isTrue);
      expect(report.usedDefaults, isTrue);
      expect(runner.calls.map((c) => c.$1.join(' ')), [
        'dart format --output=none --set-exit-if-changed .',
        'dart analyze --fatal-infos',
        'dart test',
      ]);
      expect(report.notes.single, contains('check_layers'));
      expect(report.summary(), startsWith('run_gate: DONE'));
    },
  );

  test('a Flutter project is tested with flutter test', () async {
    writeFiles(root, {
      'pubspec.yaml':
          'name: app\ndependencies:\n  flutter:\n    sdk: flutter\n',
    });
    final runner = FakeRunner();
    await runGate(root, runner: runner.call);
    expect(runner.calls.last.$1, ['flutter', 'test']);
  });

  test('one failing step means not done, and every step still runs', () async {
    final runner = FakeRunner(failing: {'analyze'});
    final report = await runGate(root, runner: runner.call);
    expect(report.done, isFalse);
    expect(report.steps.map((s) => s.status), [
      StepStatus.passed,
      StepStatus.failed,
      StepStatus.passed,
    ]);
    expect(report.summary(), contains('NOT DONE. 2/3'));
    expect(report.summary(), contains('First failing step "analyze"'));
  });

  test('fail_fast stops at the first failure', () async {
    final runner = FakeRunner(failing: {'format'});
    final report = await runGate(root, runner: runner.call, failFast: true);
    expect(report.steps, hasLength(1));
    expect(runner.calls, hasLength(1));
  });

  test('a timed-out step is not done', () async {
    final runner = FakeRunner(timingOut: {'test'});
    final report = await runGate(root, runner: runner.call);
    expect(report.done, isFalse);
    expect(report.steps.last.status, StepStatus.timedOut);
    expect(report.steps.last.output, contains('Timed out'));
  });

  test('no test directory fails the default test step', () async {
    Directory(p.join(root, 'test')).deleteSync(recursive: true);
    final report = await runGate(root, runner: FakeRunner().call);
    expect(report.done, isFalse);
    expect(report.steps.last.output, contains('No test/ directory'));
  });

  test('configured steps, builtins and step selection', () async {
    writeFiles(root, {
      'lib/core/x.dart': "import 'dart:io';\n",
      'verify_gate.yaml': '''
layers:
  - name: core is pure
    paths: [lib/core]
    forbid: ['dart:io']
gate:
  steps:
    - name: hello
      run: dart --version
      working_directory: lib
    - name: layers
      builtin: check_layers
''',
    });
    final runner = FakeRunner();
    final report = await runGate(root, runner: runner.call);
    expect(report.usedDefaults, isFalse);
    expect(report.steps.map((s) => (s.name, s.status)), [
      ('hello', StepStatus.passed),
      ('layers', StepStatus.failed),
    ]);
    expect(report.steps.last.output, contains('lib/core/x.dart:1'));
    expect(p.basename(runner.calls.single.$2), 'lib');
    expect(report.done, isFalse);

    final only = await runGate(
      root,
      runner: runner.call,
      onlySteps: ['hello', 'nope'],
    );
    expect(only.steps.map((s) => s.name), ['hello']);
    expect(only.done, isTrue);
    expect(only.notes.single, contains('nope'));
  });

  test('a broken config is an error, not silently the defaults', () async {
    writeFiles(root, {'verify_gate.yaml': 'gate: [nope'});
    expect(
      () => runGate(root, runner: FakeRunner().call),
      throwsA(isA<ConfigException>()),
    );
  });

  test('condenses test-runner progress lines but keeps failures', () {
    const out = '''
00:00 +0: loading test/a_test.dart
00:01 +1: a works
00:02 +1 -1: b breaks [E]
  Expected: <1>
    Actual: <2>
00:03 +2 -1: c works
00:03 +2 -1: Some tests failed.''';
    final c = condenseProgress(out);
    expect(c, startsWith('[3 progress line(s) condensed]'));
    expect(c, contains('b breaks [E]'));
    expect(c, contains('Actual: <2>'));
    expect(c, contains('Some tests failed.'));
    expect(c, isNot(contains('a works')));
    expect(condenseProgress('just one line'), 'just one line');
  });
}

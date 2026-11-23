import 'dart:convert';

import 'package:dart_verify_mcp/dart_verify_mcp.dart';
import 'package:test/test.dart';

/// Builds `--reporter json` output for a file whose tests have the given
/// results (`success`, `failure`, `error`, or `skip`).
String reporterOutput(
  Map<String, String> results, {
  String? loadError,
  String? setUpAllError,
}) {
  final events = <Map<String, Object?>>[
    {'type': 'start', 'protocolVersion': '0.1.1'},
    {
      'type': 'testStart',
      'test': {
        'id': 1,
        'name': 'loading test/a_test.dart',
        'groupIDs': <int>[],
        'line': null,
      },
    },
  ];
  if (loadError != null) {
    events
      ..add({'type': 'error', 'testID': 1, 'error': loadError})
      ..add({
        'type': 'testDone',
        'testID': 1,
        'result': 'error',
        // Observed with package:test 1.33: the loading pseudo-test is
        // hidden when it succeeds and visible when it fails.
        'hidden': false,
        'skipped': false,
      })
      ..add({'type': 'done', 'success': false});
    return events.map(jsonEncode).join('\n');
  }
  events.add({
    'type': 'testDone',
    'testID': 1,
    'result': 'success',
    'hidden': true,
    'skipped': false,
  });
  var id = 2;
  if (setUpAllError != null) {
    events
      ..add({
        'type': 'testStart',
        'test': {'id': id, 'name': '(setUpAll)'},
      })
      ..add({'type': 'error', 'testID': id, 'error': setUpAllError})
      ..add({
        'type': 'testDone',
        'testID': id,
        'result': 'error',
        'hidden': true,
        'skipped': false,
      });
    id++;
  }
  results.forEach((name, result) {
    final testId = id++;
    events.add({
      'type': 'testStart',
      'test': {'id': testId, 'name': name, 'line': 10 + testId},
    });
    if (result == 'failure' || result == 'error') {
      events.add({
        'type': 'error',
        'testID': testId,
        'error': 'Expected: <1>\n  Actual: <2>',
        'isFailure': result == 'failure',
      });
    }
    events.add({
      'type': 'testDone',
      'testID': testId,
      'result': result == 'skip' ? 'success' : result,
      'hidden': false,
      'skipped': result == 'skip',
    });
  });
  events.add({'type': 'done', 'success': true});
  return events.map(jsonEncode).join('\n');
}

void main() {
  diffTests();

  group('parseJsonReporter', () {
    test('collects visible tests and ignores hidden pseudo-tests', () {
      final run = parseJsonReporter(
        'Building flutter tool...\n'
        '${reporterOutput({'g a': 'success', 'g b': 'failure', 'c': 'skip'})}',
      );
      expect(run.ran, isTrue);
      expect(run.tests.map((t) => (t.name, t.result, t.skipped)), [
        ('g a', 'success', false),
        ('g b', 'failure', false),
        ('c', 'success', true),
      ]);
      expect(run.tests[1].errors.single, contains('Expected'));
    });

    test('a failed loading pseudo-test is a load error', () {
      final run = parseJsonReporter(
        reporterOutput({}, loadError: "Error: Method not found: 'clamp'."),
      );
      expect(run.ran, isFalse);
      expect(run.loadError, contains('clamp'));
    });

    test('a real test named "loading ..." is still a test', () {
      final run = parseJsonReporter(
        reporterOutput({'loading data': 'failure'}),
      );
      expect(run.loadError, isNull);
      expect(run.tests.single.name, 'loading data');
    });

    test('no JSON at all is reported as a load error with the output', () {
      final run = parseJsonReporter('', stderr: 'Could not find package test');
      expect(run.loadError, contains('Could not find package test'));
    });
  });

  group('classify', () {
    SuiteRun run(
      Map<String, String> r, {
      String? loadError,
      String? setUpAll,
    }) => parseJsonReporter(
      reporterOutput(r, loadError: loadError, setUpAllError: setUpAll),
    );

    test('fails on base and passes now: FAILS_ON_BASE', () {
      final v = classify(run({'t': 'failure'}), run({'t': 'success'}));
      expect(v.single.verdict, Verdict.failsOnBase);
      expect(v.single.verdict.detectsChange, isTrue);
    });

    test('passes on base too: PASSES_ON_BASE', () {
      final v = classify(run({'t': 'success'}), run({'t': 'success'}));
      expect(v.single.verdict, Verdict.passesOnBase);
      expect(v.single.verdict.detectsChange, isFalse);
    });

    test('does not compile on base: ERROR, which counts as detecting', () {
      final v = classify(
        run({}, loadError: 'Error: undefined name'),
        run({'t1': 'success', 't2': 'success'}),
      );
      expect(v.map((x) => (x.name, x.verdict)), [
        ('t1', Verdict.error),
        ('t2', Verdict.error),
      ]);
      expect(v.first.detail, contains('undefined name'));
      final real = classify(
        run(
          {},
          loadError:
              'Failed to load "test/a_test.dart":\n'
              "test/a_test.dart:3:38: Error: Method not found: 'nope'.",
        ),
        run({'t': 'success'}),
      );
      expect(real.single.detail, contains("Method not found: 'nope'"));
    });

    test('fails on the current code: FAILS_ON_CURRENT, whatever base did', () {
      final v = classify(run({'t': 'failure'}), run({'t': 'failure'}));
      expect(v.single.verdict, Verdict.failsOnCurrent);
      final whole = classify(run({'t': 'failure'}), run({}, loadError: 'x'));
      expect(whole.single.verdict, Verdict.failsOnCurrent);
      expect(whole.single.name, isNull);
    });

    test('skipped and timed-out runs prove nothing', () {
      expect(
        classify(run({'t': 'failure'}), run({'t': 'skip'})).single.verdict,
        Verdict.skipped,
      );
      expect(
        classify(
          SuiteRun(tests: const [], timedOut: true),
          run({'t': 'success'}),
        ).single.verdict,
        Verdict.inconclusive,
      );
    });

    test('a setUpAll failure on base is ERROR with the reason', () {
      final v = classify(
        run({}, setUpAll: 'MissingPluginException'),
        run({'t': 'success'}),
      );
      expect(v.single.verdict, Verdict.error);
      expect(v.single.detail, contains('MissingPluginException'));
    });

    test('duplicate names are matched by occurrence', () {
      final v = classify(
        run({'same': 'failure'}).withExtra('same', 'success'),
        run({'same': 'success'}).withExtra('same', 'success'),
      );
      expect(v.map((x) => x.verdict), [
        Verdict.failsOnBase,
        Verdict.passesOnBase,
      ]);
    });

    test('without a current-code run, judges from base alone', () {
      final v = classify(run({'a': 'failure', 'b': 'success'}), null);
      expect(v.map((x) => x.verdict), [
        Verdict.failsOnBase,
        Verdict.passesOnBase,
      ]);
      expect(
        classify(run({}, loadError: 'nope'), null).single.verdict,
        Verdict.error,
      );
    });
  });
}

void diffTests() {
  group('parseChangedLines', () {
    test('reads new-side ranges, including pure deletions', () {
      const diff = '''
diff --git a/t.dart b/t.dart
@@ -3 +3 @@ void main() {
@@ -10,0 +11,4 @@
@@ -20,2 +24,0 @@
''';
      expect(parseChangedLines(diff), [(3, 3), (11, 14), (24, 24)]);
    });
  });

  group('markInDiff', () {
    TestVerdict v(String name, int line) => TestVerdict(
      name: name,
      line: line,
      verdict: Verdict.passesOnBase,
      detail: '',
    );

    // Line numbers below are 1-based positions in this source.
    const source = '''
import 'package:test/test.dart';

void main() {
  test('one-liner', () => expect(1, 1));

  test('multi-line', () {
    expect(2, 2);
  });

  group('g', () {
    int helper() => 3;

    test(
      'formatted call',
      () => expect(helper(), 3),
    );
  });
}
''';
    final lines = source.split('\n');
    final tests = [
      v('one-liner', 4),
      v('multi-line', 6),
      v('g formatted call', 13),
    ];

    List<bool> judge(List<(int, int)> changed) => [
      for (final t in markInDiff(tests, changed, fileLines: lines).$1) t.inDiff,
    ];

    test('a test owns its body, found by indentation', () {
      expect(judge([(4, 4)]), [true, false, false]);
      expect(judge([(7, 7)]), [false, true, false]);
      expect(judge([(15, 15)]), [false, false, true]);
    });

    test('helpers and group headers between tests belong to no test', () {
      // The Van case: a new group with a helper, inserted after an old test,
      // must not mark the old test as changed.
      final (marked, outside) = markInDiff(tests, [(10, 11)], fileLines: lines);
      expect(marked.map((t) => t.inDiff), [false, false, false]);
      expect(outside, 2);
    });

    test('blank and bracket-only changed lines do not count', () {
      expect(judge([(5, 5), (8, 8)]), [false, false, false]);
    });

    test('tests without a known line are left in scope', () {
      final (marked, _) = markInDiff(
        [TestVerdict(name: 'x', verdict: Verdict.error, detail: '')],
        [(1, 1)],
        fileLines: lines,
      );
      expect(marked.single.inDiff, isTrue);
    });
  });
}

extension on SuiteRun {
  SuiteRun withExtra(String name, String result) => SuiteRun(
    tests: [
      ...tests,
      TestOutcome(name: name, result: result, skipped: false),
    ],
    loadError: loadError,
  );
}

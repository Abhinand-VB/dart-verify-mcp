import 'dart:convert';

/// The outcome of one test, as reported by the `json` reporter of
/// `dart test` / `flutter test`.
class TestOutcome {
  TestOutcome({
    required this.name,
    required this.result,
    required this.skipped,
    this.errors = const [],
    this.line,
  });

  /// Full name, including enclosing group names.
  final String name;

  /// `success`, `failure` (an expectation failed) or `error` (an exception).
  final String result;
  final bool skipped;
  final List<String> errors;
  final int? line;

  bool get passed => result == 'success' && !skipped;
}

/// Everything learned from running one test file.
class SuiteRun {
  SuiteRun({
    required this.tests,
    this.loadError,
    this.hiddenErrors = const [],
    this.timedOut = false,
    this.setupError,
    this.rawTail = '',
  });

  /// Tests in run order. Hidden pseudo-tests (loading, setUpAll) excluded.
  final List<TestOutcome> tests;

  /// Set when the file failed to load, which for a test copied onto older
  /// code almost always means it did not compile there.
  final String? loadError;

  /// Errors from hidden setUpAll/tearDownAll pseudo-tests.
  final List<String> hiddenErrors;
  final bool timedOut;

  /// Set when the environment could not be prepared (pub get, setup
  /// commands), so the tests never ran.
  final String? setupError;

  /// The end of the raw output, for diagnosing a run that produced no
  /// events.
  final String rawTail;

  bool get ran => !timedOut && setupError == null && loadError == null;
}

/// Parses the line-delimited JSON events printed by `--reporter json`.
///
/// Lines that are not JSON objects are ignored, because `flutter test` can
/// interleave plain build output with the events.
SuiteRun parseJsonReporter(String stdout, {String stderr = ''}) {
  final starts = <int, Map<String, Object?>>{};
  final errors = <int, List<String>>{};
  final tests = <TestOutcome>[];
  final hiddenErrors = <String>[];
  String? loadError;
  var sawAnyEvent = false;

  for (final raw in const LineSplitter().convert(stdout)) {
    final line = raw.trim();
    if (!line.startsWith('{')) continue;
    Object? event;
    try {
      event = jsonDecode(line);
    } on FormatException {
      continue;
    }
    if (event is! Map<String, Object?>) continue;
    sawAnyEvent = true;
    switch (event['type']) {
      case 'testStart':
        final test = event['test'];
        if (test is Map<String, Object?> && test['id'] is int) {
          starts[test['id'] as int] = test;
        }
      case 'error':
        final id = event['testID'];
        if (id is int) {
          (errors[id] ??= []).add('${event['error'] ?? ''}'.trim());
        }
      case 'testDone':
        final id = event['testID'];
        if (id is! int) continue;
        final start = starts[id];
        final name = '${start?['name'] ?? 'test $id'}';
        final result = '${event['result'] ?? 'error'}';
        final errs = errors[id] ?? const <String>[];
        // The runner's "loading <file>" pseudo-test is hidden when it
        // succeeds but NOT when it fails, so it is recognised by shape: that
        // name, no source line, no enclosing group.
        final isLoad =
            name.startsWith('loading ') &&
            start?['line'] == null &&
            ((start?['groupIDs'] as List?)?.isEmpty ?? true);
        if (isLoad) {
          if (result != 'success') {
            loadError = errs.isEmpty ? 'failed to load' : errs.join('\n');
          }
          continue;
        }
        if (event['hidden'] == true) {
          if (result != 'success') {
            hiddenErrors.add('$name: ${errs.join('\n')}');
          }
          continue;
        }
        tests.add(
          TestOutcome(
            name: name,
            result: result,
            skipped: event['skipped'] == true,
            errors: errs,
            line: start?['line'] is int ? start!['line'] as int : null,
          ),
        );
    }
  }

  if (!sawAnyEvent && loadError == null) {
    final tail = '$stdout\n$stderr'.trim();
    loadError = tail.isEmpty
        ? 'the test runner produced no output'
        : 'the test runner produced no JSON events:\n'
              '${_tail(tail)}';
  }
  return SuiteRun(
    tests: tests,
    loadError: loadError,
    hiddenErrors: hiddenErrors,
    rawTail: _tail('$stdout\n$stderr'.trim()),
  );
}

String _tail(String s, {int max = 2000}) =>
    s.length <= max ? s : '...${s.substring(s.length - max)}';

/// The verdict for one test.
enum Verdict {
  /// Fails on the base ref and passes now: the test detects the change.
  failsOnBase('FAILS_ON_BASE'),

  /// Passes on the base ref too: it may not test the change at all.
  passesOnBase('PASSES_ON_BASE'),

  /// Could not run on the base ref, usually because it does not compile
  /// there (it references code that did not exist yet). Counts as detecting
  /// the change, but is labelled separately because "does not compile" is a
  /// weaker signal than "runs and fails".
  error('ERROR'),

  /// Fails on the current code as well. Failing on base proves nothing about
  /// a test that fails everywhere.
  failsOnCurrent('FAILS_ON_CURRENT'),

  /// Skipped, so it proves nothing either way.
  skipped('SKIPPED'),

  /// The run could not be judged: timeout, environment failure, or the test
  /// was not reported.
  inconclusive('INCONCLUSIVE');

  const Verdict(this.id);
  final String id;

  /// Whether this verdict is evidence that the test exercises the change.
  bool get detectsChange => this == failsOnBase || this == error;
}

class TestVerdict {
  TestVerdict({
    required this.name,
    required this.verdict,
    required this.detail,
    this.baseResult,
    this.currentResult,
  });

  final String? name;
  final Verdict verdict;
  final String detail;
  final String? baseResult;
  final String? currentResult;

  Map<String, Object?> toJson() => {
    'name': name,
    'verdict': verdict.id,
    if (baseResult != null) 'base_result': baseResult,
    if (currentResult != null) 'current_result': currentResult,
    'detail': detail,
  };
}

String _result(TestOutcome t) => t.skipped ? 'skipped' : t.result;

String _firstLine(String s) {
  final l = s.trim().split('\n').first;
  return l.length > 300 ? '${l.substring(0, 300)}...' : l;
}

/// Combines the base-ref run and (optionally) the current-code run of one
/// test file into per-test verdicts.
List<TestVerdict> classify(SuiteRun base, SuiteRun? current) {
  if (current != null && !current.ran) {
    final why = current.timedOut
        ? 'timed out on the current code'
        : current.setupError != null
        ? 'could not prepare the current-code worktree: ${current.setupError}'
        : 'did not load on the current code: '
              '${_firstLine(current.loadError!)}';
    return [
      TestVerdict(
        name: null,
        verdict: current.timedOut || current.setupError != null
            ? Verdict.inconclusive
            : Verdict.failsOnCurrent,
        detail: 'The whole file $why.',
      ),
    ];
  }

  // Match by name, then by occurrence, since names can repeat.
  final baseByName = <String, List<TestOutcome>>{};
  for (final t in base.tests) {
    (baseByName[t.name] ??= []).add(t);
  }
  final seen = <String, int>{};

  TestVerdict judge(TestOutcome? now, String name) {
    final idx = seen[name] = (seen[name] ?? -1) + 1;
    final list = baseByName[name];
    final then = list != null && idx < list.length ? list[idx] : null;
    final currentResult = now == null ? null : _result(now);
    TestVerdict v(Verdict verdict, String detail) => TestVerdict(
      name: name,
      verdict: verdict,
      detail: detail,
      baseResult: then == null ? null : _result(then),
      currentResult: currentResult,
    );

    if (now != null && now.skipped) {
      return v(Verdict.skipped, 'Skipped on the current code.');
    }
    if (now != null && !now.passed) {
      return v(
        Verdict.failsOnCurrent,
        'Fails on the current code too'
        '${now.errors.isEmpty ? '' : ': ${_firstLine(now.errors.first)}'}. '
        'Fix it before reading anything into the base run.',
      );
    }
    if (base.timedOut) {
      return v(Verdict.inconclusive, 'The base run timed out.');
    }
    if (base.setupError != null) {
      return v(
        Verdict.inconclusive,
        'Could not prepare the base worktree: ${base.setupError}',
      );
    }
    if (base.loadError != null) {
      return v(
        Verdict.error,
        'Did not load on base, which usually means it references code that '
        'did not exist yet: ${_firstLine(base.loadError!)}',
      );
    }
    if (then == null) {
      return v(
        Verdict.error,
        base.hiddenErrors.isNotEmpty
            ? 'Did not run on base because setup failed there: '
                  '${_firstLine(base.hiddenErrors.first)}'
            : 'Not reported by the base run.',
      );
    }
    if (then.skipped) {
      return v(Verdict.inconclusive, 'Skipped on base.');
    }
    if (then.passed) {
      return v(
        Verdict.passesOnBase,
        'Passes on the base ref as well, so it may not test the change. '
        'Strengthen it until it fails without the change.',
      );
    }
    return v(
      Verdict.failsOnBase,
      'Fails on base (${then.result})'
      '${then.errors.isEmpty ? '' : ': ${_firstLine(then.errors.first)}'}.',
    );
  }

  if (current != null) {
    return [for (final t in current.tests) judge(t, t.name)];
  }

  // No current-code run: judge from the base run alone.
  if (!base.ran) {
    return [
      TestVerdict(
        name: null,
        verdict: base.loadError != null ? Verdict.error : Verdict.inconclusive,
        detail: base.loadError != null
            ? 'The file did not load on base, which usually means it '
                  'references code that did not exist yet: '
                  '${_firstLine(base.loadError!)}'
            : base.timedOut
            ? 'The base run timed out.'
            : 'Could not prepare the base worktree: ${base.setupError}',
      ),
    ];
  }
  return [for (final t in base.tests) judge(null, t.name)];
}

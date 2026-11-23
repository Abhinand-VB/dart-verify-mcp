import 'dart:io';

import 'package:path/path.dart' as p;

import 'config.dart';
import 'layers.dart';
import 'process_runner.dart';
import 'pubspec.dart';
import 'unused_deps.dart';

enum StepStatus {
  passed,
  failed,
  timedOut('timed_out'),
  error;

  const StepStatus([this._id]);
  final String? _id;
  String get id => _id ?? name;
}

class StepResult {
  StepResult({
    required this.name,
    required this.status,
    required this.duration,
    required this.output,
    this.command,
    this.exitCode,
  });

  final String name;
  final StepStatus status;
  final Duration duration;
  final String output;
  final String? command;
  final int? exitCode;

  Map<String, Object?> toJson() => {
    'name': name,
    'status': status.id,
    if (command != null) 'command': command,
    if (exitCode != null) 'exit_code': exitCode,
    'duration_ms': duration.inMilliseconds,
    'output': output,
  };
}

class GateReport {
  GateReport(this.steps, {required this.usedDefaults, this.notes = const []});

  final List<StepResult> steps;
  final bool usedDefaults;
  final List<String> notes;

  /// True only if there was at least one step and every step passed.
  bool get done =>
      steps.isNotEmpty && steps.every((s) => s.status == StepStatus.passed);

  Map<String, Object?> toJson() => {
    'done': done,
    'passed': steps.where((s) => s.status == StepStatus.passed).length,
    'total': steps.length,
    'steps_source': usedDefaults ? 'defaults' : configFileName,
    'steps': [for (final s in steps) s.toJson()],
    if (notes.isNotEmpty) 'notes': notes,
  };

  String summary() {
    final failing = [
      for (final s in steps)
        if (s.status != StepStatus.passed) s,
    ];
    final b = StringBuffer(
      done
          ? 'run_gate: DONE. All ${steps.length} step(s) passed.'
          : 'run_gate: NOT DONE. ${steps.length - failing.length}/'
                '${steps.length} step(s) passed.',
    );
    for (final s in steps) {
      b.write(
        '\n  ${s.status.id.padRight(9)} ${s.name} '
        '(${(s.duration.inMilliseconds / 1000).toStringAsFixed(1)}s)',
      );
    }
    for (final s in failing.take(1)) {
      b.write('\n\nFirst failing step "${s.name}" output:\n${s.output}');
    }
    return b.toString();
  }
}

/// The steps used when verify_gate.yaml has no `gate:` section.
///
/// Format is checked with `--output=none` so the gate reports unformatted
/// files instead of rewriting them: a check that silently fixes what it
/// checks hides the fact that the agent left the tree unformatted.
List<GateStep> defaultSteps(String projectRoot, VerifyConfig config) {
  final isFlutter =
      File(p.join(projectRoot, 'pubspec.yaml')).existsSync() &&
      Pubspec.load(projectRoot).isFlutter;
  return [
    GateStep(
      name: 'format',
      command: [
        'dart',
        'format',
        '--output=none',
        '--set-exit-if-changed',
        '.',
      ],
      timeoutSeconds: 300,
    ),
    GateStep(
      name: 'analyze',
      command: ['dart', 'analyze', '--fatal-infos'],
      timeoutSeconds: 600,
    ),
    if (config.layers.isNotEmpty)
      GateStep(name: 'check_layers', builtin: 'check_layers'),
    GateStep(
      name: 'test',
      command: [if (isFlutter) 'flutter' else 'dart', 'test'],
      timeoutSeconds: 1800,
    ),
  ];
}

/// Runs the gate for [projectRoot]. Every step runs (unless [failFast]), so
/// one report shows everything that is red.
Future<GateReport> runGate(
  String projectRoot, {
  VerifyConfig? config,
  bool failFast = false,
  List<String>? onlySteps,
  CommandRunner runner = runCommand,
}) async {
  final root = p.normalize(p.absolute(projectRoot));
  final cfg = config ?? VerifyConfig.load(root);
  final usedDefaults = cfg.gateSteps == null;
  var steps = cfg.gateSteps ?? defaultSteps(root, cfg);
  final notes = <String>[];
  if (usedDefaults && cfg.layers.isEmpty) {
    notes.add(
      'No layers in $configFileName, so check_layers is not part of the '
      'default gate.',
    );
  }
  if (onlySteps != null) {
    final unknown = onlySteps.where((n) => !steps.any((s) => s.name == n));
    if (unknown.isNotEmpty) {
      notes.add('Unknown step name(s) ignored: ${unknown.join(', ')}.');
    }
    steps = [
      for (final s in steps)
        if (onlySteps.contains(s.name)) s,
    ];
  }

  final results = <StepResult>[];
  for (final step in steps) {
    final watch = Stopwatch()..start();
    StepResult result;
    if (step.builtin != null) {
      result = _runBuiltin(step, root, cfg, watch);
    } else {
      final cwd = step.workingDirectory == null
          ? root
          : p.normalize(p.join(root, step.workingDirectory));
      final missingTests =
          step.name == 'test' &&
          usedDefaults &&
          !Directory(p.join(root, 'test')).existsSync();
      if (missingTests) {
        result = StepResult(
          name: step.name,
          status: StepStatus.failed,
          duration: watch.elapsed,
          command: step.command!.join(' '),
          output:
              'No test/ directory, so nothing shows this code works. Add '
              'tests, or define gate steps explicitly in $configFileName.',
        );
      } else {
        final outcome = await runner(
          step.command!,
          workingDirectory: cwd,
          timeout: Duration(seconds: step.timeoutSeconds),
        );
        result = StepResult(
          name: step.name,
          status: outcome.timedOut
              ? StepStatus.timedOut
              : outcome.startError != null
              ? StepStatus.error
              : outcome.exitCode == 0
              ? StepStatus.passed
              : StepStatus.failed,
          duration: outcome.duration,
          command: outcome.commandLine,
          exitCode: outcome.exitCode,
          output: outcome.timedOut
              ? 'Timed out after ${step.timeoutSeconds}s and was killed.\n'
                    '${trimOutput(outcome.combinedOutput, maxLines: 30)}'
              : trimOutput(condenseProgress(outcome.combinedOutput)),
        );
      }
    }
    results.add(result);
    if (failFast && result.status != StepStatus.passed) break;
  }
  return GateReport(results, usedDefaults: usedDefaults, notes: notes);
}

StepResult _runBuiltin(
  GateStep step,
  String root,
  VerifyConfig cfg,
  Stopwatch watch,
) {
  try {
    switch (step.builtin) {
      case 'check_layers':
        final report = checkLayers(root, cfg.layers, configSource: cfg.source);
        final noRules = cfg.layers.isEmpty;
        return StepResult(
          name: step.name,
          status:
              report.passed && !noRules && report.rulesMatchingNoFiles.isEmpty
              ? StepStatus.passed
              : StepStatus.failed,
          duration: watch.elapsed,
          output: noRules
              ? 'check_layers is a gate step but $configFileName defines no '
                    'layers, so it would check nothing.'
              : report.summary(),
        );
      case 'unused_dependencies':
        final report = findUnusedDependencies(
          root,
          includeDev: cfg.includeDev,
          allow: cfg.dependencyAllow,
        );
        return StepResult(
          name: step.name,
          status: report.candidateCount == 0
              ? StepStatus.passed
              : StepStatus.failed,
          duration: watch.elapsed,
          output: report.summary(),
        );
    }
  } on Object catch (e) {
    return StepResult(
      name: step.name,
      status: StepStatus.error,
      duration: watch.elapsed,
      output: '$e',
    );
  }
  return StepResult(
    name: step.name,
    status: StepStatus.error,
    duration: watch.elapsed,
    output: 'Unknown builtin ${step.builtin}',
  );
}

final _progressLine = RegExp(r'^\d+:\d+ \+\d+');

/// Drops the per-test progress lines that `dart test` / `flutter test` print
/// when not attached to a terminal (`00:03 +12: some test`), keeping the
/// last one, any line marking a failure (`[E]`), and every other line, so
/// failure details survive trimming.
String condenseProgress(String output) {
  final lines = output.split('\n');
  final progress = [
    for (var i = 0; i < lines.length; i++)
      if (_progressLine.hasMatch(lines[i])) i,
  ];
  if (progress.length < 3) return output;
  final last = progress.last;
  final out = <String>[];
  var dropped = 0;
  for (var i = 0; i < lines.length; i++) {
    final l = lines[i];
    final isProgress = _progressLine.hasMatch(l);
    if (isProgress && i != last && !l.contains('[E]')) {
      dropped++;
      continue;
    }
    out.add(l);
  }
  return dropped == 0
      ? output
      : '[$dropped progress line(s) condensed]\n${out.join('\n')}';
}

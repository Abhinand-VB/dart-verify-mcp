import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// The result of running one external command.
class ProcessOutcome {
  ProcessOutcome({
    required this.command,
    required this.workingDirectory,
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.timedOut,
    required this.duration,
    this.startError,
  });

  final List<String> command;
  final String workingDirectory;

  /// Null if the process could not be started or was killed on timeout.
  final int? exitCode;
  final String stdout;
  final String stderr;
  final bool timedOut;
  final Duration duration;

  /// Set when the executable could not be started at all.
  final String? startError;

  bool get succeeded => !timedOut && startError == null && exitCode == 0;

  String get commandLine => command.join(' ');

  /// Stdout and stderr together, for display.
  String get combinedOutput => [
    if (stdout.trim().isNotEmpty) stdout.trimRight(),
    if (stderr.trim().isNotEmpty) stderr.trimRight(),
    ?startError,
  ].join('\n');
}

/// Signature of [runCommand], so tools can be tested with a fake runner.
typedef CommandRunner =
    Future<ProcessOutcome> Function(
      List<String> command, {
      required String workingDirectory,
      required Duration timeout,
    });

const _maxCapture = 20 * 1024 * 1024;

/// Runs [command] in [workingDirectory] and never waits longer than
/// [timeout]. On timeout the whole process tree is killed (on Windows via
/// `taskkill /T`; elsewhere the direct child and its children via `pkill -P`).
///
/// On Windows the command runs through the shell so that `flutter` (a .bat
/// file) resolves the same way it does in a terminal.
Future<ProcessOutcome> runCommand(
  List<String> command, {
  required String workingDirectory,
  required Duration timeout,
}) async {
  final watch = Stopwatch()..start();
  final Process process;
  try {
    final (exe, shell) = Platform.isWindows
        ? _resolveWindows(command.first)
        : (command.first, false);
    process = await Process.start(
      exe,
      command.sublist(1),
      workingDirectory: workingDirectory,
      runInShell: shell,
    );
  } on ProcessException catch (e) {
    return ProcessOutcome(
      command: command,
      workingDirectory: workingDirectory,
      exitCode: null,
      stdout: '',
      stderr: '',
      timedOut: false,
      duration: watch.elapsed,
      startError: 'Could not start "${command.first}": ${e.message}',
    );
  }
  unawaited(process.stdin.close().catchError((_) {}));

  final out = _Capture();
  final err = _Capture();
  final outDone = process.stdout.listen(out.add).asFuture<void>();
  final errDone = process.stderr.listen(err.add).asFuture<void>();

  var timedOut = false;
  int? code;
  try {
    code = await process.exitCode.timeout(timeout);
  } on TimeoutException {
    timedOut = true;
    await _killTree(process);
    code = await process.exitCode
        .timeout(const Duration(seconds: 10))
        .then<int?>((c) => c, onError: (_) => null);
  }
  // Grandchildren can hold the pipes open after the child exits; do not let
  // that turn into a hang.
  await Future.wait([
    outDone,
    errDone,
  ]).timeout(const Duration(seconds: 5), onTimeout: () => const []);

  return ProcessOutcome(
    command: command,
    workingDirectory: workingDirectory,
    exitCode: timedOut ? null : code,
    stdout: out.text,
    stderr: err.text,
    timedOut: timedOut,
    duration: watch.elapsed,
  );
}

/// Resolves [name] the way cmd.exe would: each PATH directory in order,
/// trying .com, .exe, .bat and .cmd. A batch file (such as `flutter.bat`)
/// has to run through the shell; anything else runs directly, so arguments
/// like `HEAD^{commit}` reach the program without cmd.exe rewriting them.
(String, bool) _resolveWindows(String name) {
  if (name.contains(r'\') || name.contains('/') || name.contains('.')) {
    final lower = name.toLowerCase();
    return (name, lower.endsWith('.bat') || lower.endsWith('.cmd'));
  }
  final path = Platform.environment['PATH'] ?? '';
  for (final dir in path.split(';')) {
    if (dir.isEmpty) continue;
    for (final ext in const ['.com', '.exe', '.bat', '.cmd']) {
      final candidate = '$dir\\$name$ext';
      if (File(candidate).existsSync()) {
        return (candidate, ext == '.bat' || ext == '.cmd');
      }
    }
  }
  return (name, true);
}

Future<void> _killTree(Process process) async {
  try {
    if (Platform.isWindows) {
      await Process.run('taskkill', ['/PID', '${process.pid}', '/T', '/F']);
    } else {
      await Process.run('pkill', ['-KILL', '-P', '${process.pid}']);
      process.kill(ProcessSignal.sigkill);
    }
  } on Object {
    process.kill(ProcessSignal.sigkill);
  }
}

class _Capture {
  final _bytes = BytesBuilder(copy: false);
  var _truncated = false;

  void add(List<int> chunk) {
    if (_bytes.length >= _maxCapture) {
      _truncated = true;
      return;
    }
    _bytes.add(chunk);
  }

  String get text {
    final s = utf8.decode(_bytes.toBytes(), allowMalformed: true);
    return _truncated ? '$s\n[output truncated]' : s;
  }
}

/// Keeps the last [maxLines] lines and at most [maxChars] characters of
/// [text], marking what was cut. Gate output is for a model to read; the
/// useful part of a failing log is almost always the end.
String trimOutput(String text, {int maxLines = 60, int maxChars = 6000}) {
  final lines = const LineSplitter().convert(text.trimRight());
  var kept = lines;
  var cut = 0;
  if (lines.length > maxLines) {
    cut = lines.length - maxLines;
    kept = lines.sublist(cut);
  }
  var s = kept.join('\n');
  if (s.length > maxChars) {
    s = s.substring(s.length - maxChars);
    cut = cut == 0 ? 1 : cut;
  }
  return cut > 0 ? '[... $cut earlier line(s) omitted]\n$s' : s;
}

import 'dart:io';

import 'package:dart_verify_mcp/dart_verify_mcp.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  final dart = Platform.resolvedExecutable;

  test('captures output and exit code', () async {
    final dir = tempDir();
    writeFiles(dir, {
      'ok.dart': "import 'dart:io'; void main() { print('hi'); exit(3); }",
    });
    final r = await runCommand(
      [dart, p.join(dir, 'ok.dart')],
      workingDirectory: dir,
      timeout: const Duration(minutes: 1),
    );
    expect(r.exitCode, 3);
    expect(r.stdout.trim(), 'hi');
    expect(r.succeeded, isFalse);
    expect(r.timedOut, isFalse);
  });

  test('kills a process that outlives its timeout instead of hanging', () async {
    final dir = tempDir();
    writeFiles(dir, {
      'slow.dart':
          'Future<void> main() => Future.delayed(const Duration(minutes: 5));',
    });
    final watch = Stopwatch()..start();
    final r = await runCommand(
      [dart, p.join(dir, 'slow.dart')],
      workingDirectory: dir,
      timeout: const Duration(seconds: 3),
    );
    expect(r.timedOut, isTrue);
    expect(r.exitCode, isNull);
    expect(watch.elapsed, lessThan(const Duration(seconds: 30)));
  });

  test('reports an executable that does not exist', () async {
    final r = await runCommand(
      ['definitely-not-a-real-binary-xyz'],
      workingDirectory: Directory.current.path,
      timeout: const Duration(seconds: 30),
    );
    expect(r.succeeded, isFalse);
    // On Windows a missing command goes through cmd.exe and fails there with
    // a non-zero exit; elsewhere Process.start throws.
    expect(r.startError != null || r.exitCode != 0, isTrue);
  });

  test('trimOutput keeps the end and says what it cut', () {
    final text = [for (var i = 0; i < 100; i++) 'line $i'].join('\n');
    final t = trimOutput(text, maxLines: 10);
    expect(t, startsWith('[... 90 earlier line(s) omitted]'));
    expect(t, endsWith('line 99'));
    expect(trimOutput('short'), 'short');
  });
}

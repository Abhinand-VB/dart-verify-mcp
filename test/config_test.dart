import 'package:dart_verify_mcp/dart_verify_mcp.dart';
import 'package:test/test.dart';

void main() {
  group('VerifyConfig.parse', () {
    test('an empty file means defaults', () {
      final c = VerifyConfig.parse('');
      expect(c.layers, isEmpty);
      expect(c.gateSteps, isNull);
      expect(c.includeDev, isFalse);
    });

    test('reads layers, dependency allowlist, gate and prove_tests', () {
      final c = VerifyConfig.parse(r'''
layers:
  - name: core
    paths: [packages/core/lib]
    allow: ['dart:core', 'package:meta/']
    forbid: ['package:flutter/']
    forbid_code:
      - 'DateTime\s*\.\s*now\s*\('
      - pattern: claude
        ignore_case: true
    reason: keep the core pure
unused_dependencies:
  include_dev: true
  allow:
    - flutter_launcher_icons
    - some_plugin: used from MainActivity.kt
gate:
  timeout_seconds: 30
  steps:
    - name: analyze
      run: dart analyze --fatal-infos
    - name: layers
      builtin: check_layers
    - name: quoted
      run: ["dart", "run", "tool/x.dart", "a b"]
      timeout_seconds: 5
prove_tests:
  setup: ["dart run build_runner build -d"]
  timeout_seconds: 120
''');
      final layer = c.layers.single;
      expect(layer.name, 'core');
      expect(layer.allow, ['dart:core', 'package:meta/']);
      expect(layer.forbidCode.map((p) => p.ignoreCase), [false, true]);
      expect(c.includeDev, isTrue);
      expect(c.dependencyAllow.keys, ['flutter_launcher_icons', 'some_plugin']);
      expect(c.dependencyAllow['some_plugin'], 'used from MainActivity.kt');
      final steps = c.gateSteps!;
      expect(steps.map((s) => s.name), ['analyze', 'layers', 'quoted']);
      expect(steps[0].command, ['dart', 'analyze', '--fatal-infos']);
      expect(steps[0].timeoutSeconds, 30);
      expect(steps[1].builtin, 'check_layers');
      expect(steps[2].command!.last, 'a b');
      expect(steps[2].timeoutSeconds, 5);
      expect(c.proveSetup.single, [
        'dart',
        'run',
        'build_runner',
        'build',
        '-d',
      ]);
      expect(c.proveTimeoutSeconds, 120);
    });

    test('rejects a layer that would check nothing', () {
      expect(
        () => VerifyConfig.parse('layers:\n  - name: x\n    paths: [lib]\n'),
        throwsA(isA<ConfigException>()),
      );
    });

    test('rejects a step with both run and builtin, or an unknown builtin', () {
      expect(
        () => VerifyConfig.parse('''
gate:
  steps:
    - name: x
      run: dart test
      builtin: check_layers
'''),
        throwsA(isA<ConfigException>()),
      );
      expect(
        () => VerifyConfig.parse('''
gate:
  steps:
    - name: x
      builtin: nope
'''),
        throwsA(isA<ConfigException>()),
      );
    });

    test('rejects an invalid regex instead of ignoring it', () {
      expect(
        () => VerifyConfig.parse('''
layers:
  - name: x
    paths: [lib]
    forbid_code: ['(unclosed']
'''),
        throwsA(isA<ConfigException>()),
      );
    });

    test('rejects invalid YAML', () {
      expect(
        () => VerifyConfig.parse('layers: [unclosed'),
        throwsA(isA<ConfigException>()),
      );
    });
  });

  group('splitCommand', () {
    test('splits on whitespace and honours quotes', () {
      expect(splitCommand('dart  format --output=none .'), [
        'dart',
        'format',
        '--output=none',
        '.',
      ]);
      expect(splitCommand(r'''a "b c" 'd e' "f\"g" '''), [
        'a',
        'b c',
        'd e',
        'f"g',
      ]);
      expect(splitCommand('a ""'), ['a', '']);
    });

    test('rejects an unterminated quote', () {
      expect(() => splitCommand('a "b'), throwsA(isA<ConfigException>()));
    });
  });
}

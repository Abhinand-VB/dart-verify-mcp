import 'dart:convert';
import 'dart:io';

import 'package:dart_mcp/client.dart';
import 'package:dart_mcp/stdio.dart';
import 'package:dart_verify_mcp/dart_verify_mcp.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import 'support/fixtures.dart';

/// Talks to the real server binary over stdio, as an agent would.
void main() {
  late Process process;
  late MCPClient client;
  late ServerConnection server;

  setUpAll(() async {
    process = await Process.start(Platform.resolvedExecutable, [
      'run',
      p.join('bin', 'dart_verify_mcp.dart'),
    ]);
    client = MCPClient(Implementation(name: 'test', version: '0'));
    server = client.connectServer(
      stdioChannel(input: process.stdout, output: process.stdin),
    );
    final init = await server.initialize(
      InitializeRequest(
        protocolVersion: ProtocolVersion.latestSupported,
        capabilities: client.capabilities,
        clientInfo: client.implementation,
      ),
    );
    expect(init.serverInfo.name, 'dart_verify_mcp');
    server.notifyInitialized();
  });

  tearDownAll(() async {
    await client.shutdown();
    process.kill();
  });

  test('lists the four tools', () async {
    final tools = await server.listTools();
    expect(tools.tools.map((t) => t.name), [
      'prove_tests_can_fail',
      'check_layers',
      'unused_dependencies',
      'run_gate',
    ]);
  });

  test('returns a summary, the JSON report, and structuredContent', () async {
    final root = tempDir();
    writeFiles(root, {
      'pubspec.yaml': 'name: app\n',
      'lib/core/a.dart': "import 'package:flutter/widgets.dart';\n",
      'verify_gate.yaml': '''
layers:
  - name: core has no flutter
    paths: [lib/core]
    forbid: ['package:flutter/']
''',
    });
    final result = await server.callTool(
      CallToolRequest(name: 'check_layers', arguments: {'project_root': root}),
    );
    expect(result.isError, isNot(true));
    final texts = [for (final c in result.content) (c as TextContent).text];
    expect(texts.first, contains('1 violation(s)'));
    final json = jsonDecode(texts[1]) as Map<String, Object?>;
    expect(json['passed'], isFalse);
    expect(result.structuredContent!['violation_count'], 1);
  });

  test('a missing project root is a tool error, not a crash', () async {
    final result = await server.callTool(
      CallToolRequest(
        name: 'unused_dependencies',
        arguments: {'project_root': p.join(tempDir(), 'missing')},
      ),
    );
    expect(result.isError, isTrue);
    expect((result.content.single as TextContent).text, contains('not exist'));
  });

  test('a broken verify_gate.yaml is reported as an error', () async {
    final root = tempDir();
    writeFiles(root, {
      'pubspec.yaml': 'name: app\n',
      'verify_gate.yaml': 'layers: [x',
    });
    final result = await server.callTool(
      CallToolRequest(name: 'check_layers', arguments: {'project_root': root}),
    );
    expect(result.isError, isTrue);
  });

  test('packageVersion matches pubspec.yaml', () {
    final pubspec = loadYaml(File('pubspec.yaml').readAsStringSync()) as Map;
    expect(packageVersion, pubspec['version']);
  });
}

// Starts the server as a subprocess, speaks MCP to it over stdio, and calls
// one tool. Useful for trying a tool without an agent, and it is how the
// example outputs in the README were captured.
//
//   dart run tool/call_tool.dart --list
//   dart run tool/call_tool.dart check_layers '{"project_root": "/path/to/app"}'
//
// Prints the tool's text content to stdout.
import 'dart:convert';
import 'dart:io';

import 'package:dart_mcp/client.dart';
import 'package:dart_mcp/stdio.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: call_tool.dart --list | <tool> [json-arguments]');
    exitCode = 64;
    return;
  }
  final serverScript = p.join(
    p.dirname(p.dirname(Platform.script.toFilePath())),
    'bin',
    'dart_verify_mcp.dart',
  );
  final process = await Process.start(Platform.resolvedExecutable, [
    'run',
    serverScript,
  ]);
  process.stderr.transform(utf8.decoder).listen(stderr.write);

  final client = MCPClient(Implementation(name: 'call_tool', version: '0'));
  final server = client.connectServer(
    stdioChannel(input: process.stdout, output: process.stdin),
  );
  try {
    final init = await server.initialize(
      InitializeRequest(
        protocolVersion: ProtocolVersion.latestSupported,
        capabilities: client.capabilities,
        clientInfo: client.implementation,
      ),
    );
    server.notifyInitialized();
    if (args.first == '--list') {
      stdout.writeln(
        'server: ${init.serverInfo.name} ${init.serverInfo.version}',
      );
      final tools = await server.listTools();
      for (final t in tools.tools) {
        stdout.writeln('- ${t.name}: ${t.description}');
      }
      return;
    }
    final arguments = args.length > 1
        ? (jsonDecode(args[1]) as Map).cast<String, Object?>()
        : <String, Object?>{};
    final result = await server.callTool(
      CallToolRequest(name: args.first, arguments: arguments),
    );
    for (final c in result.content) {
      if (c.isText) stdout.writeln((c as TextContent).text);
    }
    if (result.isError == true) exitCode = 1;
  } finally {
    await client.shutdown();
    process.kill();
  }
}

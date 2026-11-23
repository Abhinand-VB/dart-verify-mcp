import 'dart:io' as io;

import 'package:dart_mcp/stdio.dart';
import 'package:dart_verify_mcp/dart_verify_mcp.dart';

/// Starts the MCP server on stdin/stdout.
///
/// stdout carries the protocol, so nothing else may print to it. Child
/// processes get their own pipes.
Future<void> main(List<String> args) async {
  if (args.contains('--version')) {
    io.stderr.writeln('dart_verify_mcp $packageVersion');
    return;
  }
  final server = VerifyServer(stdioChannel(input: io.stdin, output: io.stdout));
  await server.done;
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_mcp/server.dart';
import 'package:path/path.dart' as p;

import 'config.dart';
import 'gate.dart';
import 'layers.dart';
import 'prove_tests.dart';
import 'unused_deps.dart';

/// Kept in sync with pubspec.yaml by a test.
const packageVersion = '0.1.0';

/// The MCP server. All real work lives in the tool libraries; this class only
/// validates arguments and turns reports into tool results.
base class VerifyServer extends MCPServer with ToolsSupport {
  VerifyServer(super.channel)
    : super.fromStreamChannel(
        implementation: Implementation(
          name: 'dart_verify_mcp',
          version: packageVersion,
        ),
        instructions:
            'Verification checks for Dart and Flutter projects that '
            'complement the official Dart MCP server: prove new tests can '
            'fail, enforce import layer rules, find unused dependencies, and '
            'run a single done/not-done gate. Do not report work as done '
            'unless run_gate returns done: true.',
      ) {
    registerTool(proveTestsTool, _proveTests);
    registerTool(checkLayersTool, _checkLayers);
    registerTool(unusedDepsTool, _unusedDeps);
    registerTool(runGateTool, _runGate);
  }

  static final _root = Schema.string(
    description:
        'Absolute path to the Dart or Flutter project (the directory with '
        'pubspec.yaml and, optionally, verify_gate.yaml).',
  );

  final proveTestsTool = Tool(
    name: 'prove_tests_can_fail',
    description:
        'Shows whether new or changed tests actually test the change. Runs '
        'each new/modified *_test.dart file against the code at a base git '
        'ref (in a temporary git worktree; the working tree is never '
        'modified) and reports per test: FAILS_ON_BASE (good), '
        'PASSES_ON_BASE (suspicious: it may not test the change), ERROR '
        '(did not compile on base; usually references new code), '
        'FAILS_ON_CURRENT (fails now too), SKIPPED, INCONCLUSIVE. Slow: it '
        'runs pub get and the tests twice.',
    annotations: ToolAnnotations(
      title: 'Prove tests can fail',
      readOnlyHint: false,
      destructiveHint: false,
      idempotentHint: true,
      openWorldHint: false,
    ),
    inputSchema: Schema.object(
      properties: {
        'project_root': _root,
        'base_ref': Schema.string(
          description:
              'Git ref holding the old code. Default HEAD, which checks '
              'uncommitted work. Use e.g. main or HEAD~1 for committed work.',
        ),
        'test_files': Schema.list(
          description:
              'Test files to check (relative to project_root or absolute). '
              'Default: *_test.dart files added or modified vs base_ref, '
              'plus untracked ones.',
          items: Schema.string(),
        ),
        'check_current': Schema.bool(
          description:
              'Also run the tests on the current code (in a second '
              'worktree) so a test that fails everywhere is not mistaken for '
              'one that detects the change. Default true.',
        ),
        'timeout_seconds': Schema.int(
          description: 'Per test file, per tree. Default 600.',
          minimum: 10,
        ),
      },
      required: ['project_root'],
    ),
  );

  final checkLayersTool = Tool(
    name: 'check_layers',
    description:
        'Checks import/export directives against the layer rules in '
        'verify_gate.yaml (for example: the domain core may not import '
        'package:flutter/ or dart:io). Comments and strings are ignored, '
        'multi-line and conditional imports are handled, relative imports are '
        'resolved to package: URIs. Reports file:line and the rule.',
    annotations: ToolAnnotations(
      title: 'Check import layers',
      readOnlyHint: true,
      openWorldHint: false,
    ),
    inputSchema: Schema.object(
      properties: {'project_root': _root},
      required: ['project_root'],
    ),
  );

  final unusedDepsTool = Tool(
    name: 'unused_dependencies',
    description:
        'Lists pubspec dependencies that no Dart file in the package imports '
        'or exports. Each finding is unused_candidate or likely_needed (with '
        'a reason: Flutter plugin referenced from native code, font/asset '
        'package, build_runner builder, pubspec config section, '
        'executables). Candidates are evidence, not proof: verify before '
        'removing.',
    annotations: ToolAnnotations(
      title: 'Find unused dependencies',
      readOnlyHint: true,
      openWorldHint: false,
    ),
    inputSchema: Schema.object(
      properties: {
        'project_root': _root,
        'include_dev': Schema.bool(
          description:
              'Also check dev_dependencies. Defaults to the value in '
              'verify_gate.yaml, else false.',
        ),
        'nested': Schema.bool(
          description:
              'Also check packages nested under project_root (monorepos). '
              'Default true.',
        ),
      },
      required: ['project_root'],
    ),
  );

  final runGateTool = Tool(
    name: 'run_gate',
    description:
        'Runs the project gate and returns done: true only if every step '
        'passed. Steps come from verify_gate.yaml, or default to: dart '
        'format (check only), dart analyze --fatal-infos, check_layers (if '
        'configured), and dart/flutter test. Each step has a timeout.',
    annotations: ToolAnnotations(
      title: 'Run the gate',
      readOnlyHint: false,
      destructiveHint: false,
      openWorldHint: false,
    ),
    inputSchema: Schema.object(
      properties: {
        'project_root': _root,
        'steps': Schema.list(
          description: 'Run only these step names. Default: all.',
          items: Schema.string(),
        ),
        'fail_fast': Schema.bool(
          description: 'Stop at the first failing step. Default false.',
        ),
      },
      required: ['project_root'],
    ),
  );

  Future<CallToolResult> _proveTests(CallToolRequest request) =>
      _guard(request, (root, args) async {
        final cfg = VerifyConfig.load(root);
        final timeout = args['timeout_seconds'];
        final report = await proveTestsCanFail(
          root,
          baseRef: (args['base_ref'] as String?) ?? 'HEAD',
          testFiles: (args['test_files'] as List?)?.cast<String>(),
          checkCurrent: (args['check_current'] as bool?) ?? true,
          config: cfg,
          perFileTimeout: timeout is int ? Duration(seconds: timeout) : null,
        );
        return (report.summary(), report.toJson());
      });

  Future<CallToolResult> _checkLayers(CallToolRequest request) =>
      _guard(request, (root, args) async {
        final cfg = VerifyConfig.load(root);
        final report = checkLayers(root, cfg.layers, configSource: cfg.source);
        return (report.summary(), report.toJson());
      });

  Future<CallToolResult> _unusedDeps(CallToolRequest request) =>
      _guard(request, (root, args) async {
        if (!File(p.join(root, 'pubspec.yaml')).existsSync() &&
            args['nested'] == false) {
          throw ConfigException('No pubspec.yaml in $root.');
        }
        final cfg = VerifyConfig.load(root);
        final report = findUnusedDependencies(
          root,
          includeDev: (args['include_dev'] as bool?) ?? cfg.includeDev,
          allow: cfg.dependencyAllow,
          nested: (args['nested'] as bool?) ?? true,
        );
        return (report.summary(), report.toJson());
      });

  Future<CallToolResult> _runGate(CallToolRequest request) =>
      _guard(request, (root, args) async {
        final report = await runGate(
          root,
          failFast: (args['fail_fast'] as bool?) ?? false,
          onlySteps: (args['steps'] as List?)?.cast<String>(),
        );
        return (report.summary(), report.toJson());
      });

  /// Validates `project_root`, runs [body], and packages the result as a
  /// human summary followed by the JSON report (also sent as
  /// structuredContent for clients that read it).
  Future<CallToolResult> _guard(
    CallToolRequest request,
    Future<(String, Map<String, Object?>)> Function(
      String root,
      Map<String, Object?> args,
    )
    body,
  ) async {
    final args = request.arguments ?? const <String, Object?>{};
    final rawRoot = args['project_root'];
    if (rawRoot is! String || rawRoot.isEmpty) {
      return _error('project_root is required.');
    }
    final root = p.normalize(p.absolute(rawRoot));
    if (!Directory(root).existsSync()) {
      return _error('project_root does not exist: $root');
    }
    try {
      final (summary, json) = await body(root, args);
      return CallToolResult(
        content: [
          TextContent(text: summary),
          TextContent(text: const JsonEncoder.withIndent('  ').convert(json)),
        ],
        structuredContent: json,
      );
    } on ConfigException catch (e) {
      return _error(e.message);
    } on ProveTestsException catch (e) {
      return _error(e.message);
    } on FileSystemException catch (e) {
      return _error('${e.message}: ${e.path ?? ''}');
    }
  }

  CallToolResult _error(String message) =>
      CallToolResult(isError: true, content: [TextContent(text: message)]);
}

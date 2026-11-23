import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// The name of the per-project configuration file, read from the project
/// root.
const configFileName = 'verify_gate.yaml';

/// Thrown when `verify_gate.yaml` exists but cannot be understood. A broken
/// config is reported, never silently replaced by defaults, because a gate
/// that quietly checks less than it was told to is the failure this tool
/// exists to prevent.
class ConfigException implements Exception {
  ConfigException(this.message);
  final String message;
  @override
  String toString() => 'ConfigException: $message';
}

/// A regex that must not match in a layer's code (comments removed).
class CodePattern {
  CodePattern(this.pattern, {this.ignoreCase = false});
  final String pattern;
  final bool ignoreCase;
  late final RegExp regex = RegExp(pattern, caseSensitive: !ignoreCase);
}

/// One layer rule from `verify_gate.yaml`.
class LayerRule {
  LayerRule({
    required this.name,
    required this.paths,
    this.exclude = const [],
    this.forbid = const [],
    this.allow,
    this.forbidCode = const [],
    this.reason,
  });

  final String name;

  /// Globs (relative to the project root, forward slashes) selecting the
  /// files this rule applies to.
  final List<String> paths;
  final List<String> exclude;

  /// URI patterns no import/export in the layer may match.
  final List<String> forbid;

  /// If set, every import/export with a scheme (`dart:`, `package:`) must
  /// match one of these patterns. Relative imports are judged by [forbid]
  /// against their resolved `package:` form.
  final List<String>? allow;

  /// Regexes that must not match the layer's code with comments removed.
  final List<CodePattern> forbidCode;

  /// Shown next to every violation of this rule.
  final String? reason;
}

/// One step of the gate.
class GateStep {
  GateStep({
    required this.name,
    this.command,
    this.builtin,
    this.timeoutSeconds = 600,
    this.workingDirectory,
  }) : assert((command == null) != (builtin == null));

  final String name;

  /// Executable followed by its arguments.
  final List<String>? command;

  /// `check_layers` or `unused_dependencies`.
  final String? builtin;
  final int timeoutSeconds;

  /// Relative to the project root.
  final String? workingDirectory;
}

class VerifyConfig {
  VerifyConfig({
    this.layers = const [],
    this.gateSteps,
    this.includeDev = false,
    this.dependencyAllow = const {},
    this.proveSetup = const [],
    this.proveTimeoutSeconds = 600,
    this.source,
  });

  final List<LayerRule> layers;

  /// Null means "use the defaults for this project".
  final List<GateStep>? gateSteps;
  final bool includeDev;

  /// Package name to the reason it is kept despite having no import.
  final Map<String, String> dependencyAllow;

  /// Commands run in each prove_tests worktree after `pub get`, e.g.
  /// `dart run build_runner build -d` for projects that do not commit
  /// generated code.
  final List<List<String>> proveSetup;
  final int proveTimeoutSeconds;

  /// Path of the file this was loaded from, or null for defaults.
  final String? source;

  static VerifyConfig load(String projectRoot) {
    final file = File(p.join(projectRoot, configFileName));
    if (!file.existsSync()) return VerifyConfig();
    return parse(file.readAsStringSync(), source: file.path);
  }

  static VerifyConfig parse(String text, {String? source}) {
    final Object? doc;
    try {
      doc = loadYaml(text);
    } on YamlException catch (e) {
      throw ConfigException('$configFileName is not valid YAML: ${e.message}');
    }
    if (doc == null) return VerifyConfig(source: source);
    if (doc is! Map) {
      throw ConfigException('$configFileName must be a mapping at the top.');
    }

    final layers = <LayerRule>[];
    final rawLayers = doc['layers'];
    if (rawLayers != null) {
      if (rawLayers is! List) throw ConfigException('`layers` must be a list.');
      for (final (i, raw) in rawLayers.indexed) {
        if (raw is! Map) throw ConfigException('layers[$i] must be a mapping.');
        final name = raw['name']?.toString() ?? 'layer ${i + 1}';
        final paths = _strings(raw['paths'], 'layers[$i].paths');
        if (paths.isEmpty) {
          throw ConfigException(
            'layers[$i] ("$name") needs at least one path.',
          );
        }
        final allowRaw = raw['allow'];
        final forbid = _strings(raw['forbid'], 'layers[$i].forbid');
        final forbidCode = <CodePattern>[];
        final fc = raw['forbid_code'];
        if (fc != null) {
          if (fc is! List) {
            throw ConfigException('layers[$i].forbid_code must be a list.');
          }
          for (final entry in fc) {
            if (entry is String) {
              forbidCode.add(CodePattern(entry));
            } else if (entry is Map && entry['pattern'] is String) {
              forbidCode.add(
                CodePattern(
                  entry['pattern'] as String,
                  ignoreCase: entry['ignore_case'] == true,
                ),
              );
            } else {
              throw ConfigException(
                'layers[$i].forbid_code entries must be a string or '
                '{pattern, ignore_case}.',
              );
            }
          }
          for (final c in forbidCode) {
            try {
              c.regex;
            } on FormatException catch (e) {
              throw ConfigException(
                'layers[$i].forbid_code has an invalid regex '
                '"${c.pattern}": ${e.message}',
              );
            }
          }
        }
        if (forbid.isEmpty && allowRaw == null && forbidCode.isEmpty) {
          throw ConfigException(
            'layers[$i] ("$name") has no forbid, allow or forbid_code, so it '
            'would check nothing.',
          );
        }
        layers.add(
          LayerRule(
            name: name,
            paths: paths,
            exclude: _strings(raw['exclude'], 'layers[$i].exclude'),
            forbid: forbid,
            allow: allowRaw == null
                ? null
                : _strings(allowRaw, 'layers[$i].allow'),
            forbidCode: forbidCode,
            reason: raw['reason']?.toString(),
          ),
        );
      }
    }

    var includeDev = false;
    final allow = <String, String>{};
    final deps = doc['unused_dependencies'];
    if (deps != null) {
      if (deps is! Map) {
        throw ConfigException('`unused_dependencies` must be a mapping.');
      }
      includeDev = deps['include_dev'] == true;
      final a = deps['allow'];
      if (a is List) {
        for (final e in a) {
          if (e is String) {
            allow[e] = 'allowlisted in $configFileName';
          } else if (e is Map && e.length == 1) {
            allow[e.keys.first.toString()] = e.values.first.toString();
          }
        }
      } else if (a is Map) {
        a.forEach((k, v) => allow[k.toString()] = v.toString());
      } else if (a != null) {
        throw ConfigException('`unused_dependencies.allow` must be a list.');
      }
    }

    List<GateStep>? steps;
    final gate = doc['gate'];
    if (gate != null) {
      if (gate is! Map || gate['steps'] is! List) {
        throw ConfigException('`gate` must be a mapping with a `steps` list.');
      }
      final defaultTimeout = _int(gate['timeout_seconds']) ?? 600;
      steps = [];
      for (final (i, raw) in (gate['steps'] as List).indexed) {
        if (raw is! Map) throw ConfigException('gate.steps[$i] must be a map.');
        final name = raw['name']?.toString() ?? 'step ${i + 1}';
        final builtin = raw['builtin']?.toString();
        final run = raw['run'];
        if ((builtin == null) == (run == null)) {
          throw ConfigException(
            'gate.steps[$i] ("$name") needs exactly one of `run` or `builtin`.',
          );
        }
        if (builtin != null && !builtinSteps.contains(builtin)) {
          throw ConfigException(
            'gate.steps[$i] ("$name"): unknown builtin "$builtin". '
            'Known: ${builtinSteps.join(', ')}.',
          );
        }
        final command = run == null
            ? null
            : run is List
            ? [for (final a in run) a.toString()]
            : splitCommand(run.toString());
        if (command != null && command.isEmpty) {
          throw ConfigException('gate.steps[$i] ("$name") has an empty `run`.');
        }
        steps.add(
          GateStep(
            name: name,
            command: command,
            builtin: builtin,
            timeoutSeconds: _int(raw['timeout_seconds']) ?? defaultTimeout,
            workingDirectory: raw['working_directory']?.toString(),
          ),
        );
      }
    }

    final setup = <List<String>>[];
    var proveTimeout = 600;
    final prove = doc['prove_tests'];
    if (prove is Map) {
      final s = prove['setup'];
      if (s is List) {
        for (final c in s) {
          setup.add(c is List ? [for (final a in c) '$a'] : splitCommand('$c'));
        }
      }
      proveTimeout = _int(prove['timeout_seconds']) ?? proveTimeout;
    }

    return VerifyConfig(
      layers: layers,
      gateSteps: steps,
      includeDev: includeDev,
      dependencyAllow: allow,
      proveSetup: setup,
      proveTimeoutSeconds: proveTimeout,
      source: source,
    );
  }
}

const builtinSteps = ['check_layers', 'unused_dependencies'];

int? _int(Object? v) => v is int ? v : int.tryParse('${v ?? ''}');

List<String> _strings(Object? v, String where) {
  if (v == null) return const [];
  if (v is String) return [v];
  if (v is List) return [for (final e in v) e.toString()];
  throw ConfigException('$where must be a string or a list of strings.');
}

/// Splits a command line into words. Supports single and double quotes and
/// backslash escapes inside double quotes. No globbing, variables or pipes:
/// gate steps run without a shell so they behave the same on every OS.
List<String> splitCommand(String line) {
  final words = <String>[];
  final cur = StringBuffer();
  var inWord = false;
  String? quote;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (quote != null) {
      if (c == quote) {
        quote = null;
      } else if (c == r'\' && quote == '"' && i + 1 < line.length) {
        cur.write(line[++i]);
      } else {
        cur.write(c);
      }
      continue;
    }
    if (c == '"' || c == "'") {
      quote = c;
      inWord = true;
    } else if (c == ' ' || c == '\t') {
      if (inWord) {
        words.add(cur.toString());
        cur.clear();
        inWord = false;
      }
    } else {
      cur.write(c);
      inWord = true;
    }
  }
  if (quote != null) {
    throw ConfigException('Unterminated quote in command: $line');
  }
  if (inWord) words.add(cur.toString());
  return words;
}

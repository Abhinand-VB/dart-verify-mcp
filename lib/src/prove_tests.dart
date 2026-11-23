import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'config.dart';
import 'files.dart';
import 'process_runner.dart';
import 'pubspec.dart';
import 'test_results.dart';

/// Raised for problems that stop the whole run (not a git repo, unknown
/// ref). Per-file problems are reported in the result instead.
class ProveTestsException implements Exception {
  ProveTestsException(this.message);
  final String message;
  @override
  String toString() => message;
}

class FileResult {
  FileResult({
    required this.file,
    required this.packageDir,
    required this.runner,
    required this.verdicts,
    this.note,
  });

  /// Relative to the repository root.
  final String file;
  final String? packageDir;
  final String? runner;
  final List<TestVerdict> verdicts;
  final String? note;

  Map<String, Object?> toJson() => {
    'file': file,
    'package_dir': packageDir,
    'runner': runner,
    if (note != null) 'note': note,
    'tests': [for (final v in verdicts) v.toJson()],
  };
}

class ProveTestsReport {
  ProveTestsReport({
    required this.repoRoot,
    required this.baseRef,
    required this.baseSha,
    required this.checkCurrent,
    required this.files,
    required this.carriedFiles,
    this.message,
  });

  final String repoRoot;
  final String baseRef;
  final String baseSha;
  final bool checkCurrent;
  final List<FileResult> files;

  /// Test-side files (other than the tests themselves) copied onto the base
  /// worktree, such as changed helpers under test/.
  final List<String> carriedFiles;
  final String? message;

  Iterable<TestVerdict> get _all => files.expand((f) => f.verdicts);

  Map<String, int> get counts {
    final c = {for (final v in Verdict.values) v.id: 0};
    for (final t in _all) {
      c[t.verdict.id] = c[t.verdict.id]! + 1;
    }
    return c;
  }

  /// True when there was at least one test and every one either fails on
  /// base or does not compile there, while passing on the current code.
  bool get allDetectChange =>
      _all.isNotEmpty && _all.every((t) => t.verdict.detectsChange);

  Map<String, Object?> toJson() => {
    'all_tests_detect_change': allDetectChange,
    'base_ref': baseRef,
    'base_sha': baseSha,
    'checked_current_code': checkCurrent,
    'counts': counts,
    'needs_attention': [
      for (final f in files)
        for (final t in f.verdicts)
          if (!t.verdict.detectsChange)
            {'file': f.file, 'test': t.name, 'verdict': t.verdict.id},
    ],
    'files': [for (final f in files) f.toJson()],
    'carried_test_side_files': carriedFiles,
    if (message != null) 'message': message,
  };

  String summary() {
    if (files.isEmpty) {
      return 'prove_tests_can_fail: ${message ?? 'no test files to check.'}';
    }
    final c = counts;
    final total = _all.length;
    final b = StringBuffer(
      'prove_tests_can_fail vs $baseRef (${baseSha.substring(0, 7)}): '
      '$total test(s) in ${files.length} file(s). ',
    );
    b.write(
      [
        for (final v in Verdict.values)
          if (c[v.id]! > 0) '${c[v.id]} ${v.id}',
      ].join(', '),
    );
    b.write('.');
    final attention = [
      for (final f in files)
        for (final t in f.verdicts)
          if (!t.verdict.detectsChange) (f.file, t),
    ];
    if (attention.isEmpty) {
      b.write('\nEvery test fails without the change.');
    } else {
      for (final (file, t) in attention.take(15)) {
        b.write('\n  ${t.verdict.id}: $file: ${t.name ?? '(whole file)'}');
      }
      if (attention.length > 15) {
        b.write('\n  ... ${attention.length - 15} more (see JSON).');
      }
    }
    return b.toString();
  }
}

class _Change {
  _Change(this.path, {required this.deleted});
  final String path; // repo-relative, forward slashes
  final bool deleted;
}

/// Runs new or modified tests against the code at [baseRef] to show whether
/// they can fail.
///
/// The user's working tree is never written to. Two temporary git worktrees
/// are created under the system temp directory: one at [baseRef] with only
/// the test-side files carried over, and (when [checkCurrent] is set) one at
/// [baseRef] with every working-tree change applied, so the "does it pass
/// now" half also runs without touching the user's checkout. Both are
/// removed afterwards, including on failure.
Future<ProveTestsReport> proveTestsCanFail(
  String projectRoot, {
  String baseRef = 'HEAD',
  List<String>? testFiles,
  bool checkCurrent = true,
  VerifyConfig? config,
  Duration? perFileTimeout,
  Duration pubGetTimeout = const Duration(minutes: 10),
  CommandRunner runner = runCommand,
}) async {
  final root = p.normalize(p.absolute(projectRoot));
  final cfg = config ?? VerifyConfig.load(root);
  final timeout = perFileTimeout ?? Duration(seconds: cfg.proveTimeoutSeconds);

  Future<ProcessOutcome> git(List<String> args, {String? cwd}) => runner(
    ['git', ...args],
    workingDirectory: cwd ?? root,
    timeout: const Duration(minutes: 2),
  );

  final top = await git(['rev-parse', '--show-toplevel']);
  if (!top.succeeded) {
    throw ProveTestsException(
      '$root is not inside a git repository: ${top.combinedOutput}',
    );
  }
  final repo = p.normalize(top.stdout.trim());

  final rev = await git([
    'rev-parse',
    '--verify',
    '--quiet',
    '$baseRef^{commit}',
  ]);
  if (!rev.succeeded || rev.stdout.trim().isEmpty) {
    throw ProveTestsException('Unknown base ref "$baseRef".');
  }
  final sha = rev.stdout.trim();

  final diff = await git([
    '-c',
    'core.quotepath=off',
    'diff',
    '--name-status',
    '-z',
    '--no-renames',
    sha,
  ], cwd: repo);
  if (!diff.succeeded) {
    throw ProveTestsException('git diff failed: ${diff.combinedOutput}');
  }
  final untracked = await git([
    'ls-files',
    '--others',
    '--exclude-standard',
    '-z',
  ], cwd: repo);
  final changes = <_Change>[
    ..._parseNameStatus(diff.stdout),
    for (final path in untracked.stdout.split('\x00'))
      if (path.isNotEmpty) _Change(path, deleted: false),
  ];

  final rootRel = relPosix(repo, root);
  bool underRoot(String path) =>
      rootRel == '.' || rootRel.isEmpty || path.startsWith('$rootRel/');

  final List<String> selected;
  if (testFiles != null && testFiles.isNotEmpty) {
    selected = [];
    for (final f in testFiles) {
      final abs = p.normalize(p.isAbsolute(f) ? f : p.join(root, f));
      if (!File(abs).existsSync()) {
        throw ProveTestsException('Test file not found: $f');
      }
      selected.add(relPosix(repo, abs));
    }
  } else {
    selected = [
      for (final c in changes)
        if (!c.deleted && c.path.endsWith('_test.dart') && underRoot(c.path))
          c.path,
    ]..sort();
  }

  if (selected.isEmpty) {
    return ProveTestsReport(
      repoRoot: repo,
      baseRef: baseRef,
      baseSha: sha,
      checkCurrent: checkCurrent,
      files: const [],
      carriedFiles: const [],
      message:
          'No new or modified *_test.dart files under $root compared with '
          '$baseRef (including untracked files). Pass test_files to check '
          'specific files.',
    );
  }

  // Group the tests by their package (nearest pubspec.yaml in the working
  // tree).
  final packageOf = <String, String?>{};
  for (final t in selected) {
    final dir = nearestPackageDir(p.join(repo, t), limit: repo);
    packageOf[t] = dir == null ? null : relPosix(repo, dir);
  }
  final packages = {...packageOf.values.whereType<String>()};

  // Test-side files are carried onto base with the tests: helpers under a
  // package's test/ or integration_test/ belong to the test, not to the code
  // under test.
  bool isTestSide(String path) => packages.any((pkg) {
    final prefix = pkg == '.' || pkg.isEmpty ? '' : '$pkg/';
    return path.startsWith('${prefix}test/') ||
        path.startsWith('${prefix}integration_test/') ||
        path.startsWith('${prefix}test_driver/');
  });
  final carried = <String>{
    ...selected,
    for (final c in changes)
      if (!c.deleted && isTestSide(c.path)) c.path,
  };

  final temp = await Directory.systemTemp.createTemp('dart_verify_mcp_');
  final worktrees = <String>[];
  try {
    Future<String?> addWorktree(String name) async {
      final path = p.join(temp.path, name);
      final r = await git([
        'worktree',
        'add',
        '--detach',
        path,
        sha,
      ], cwd: repo);
      if (!r.succeeded) return 'git worktree add failed: ${r.combinedOutput}';
      worktrees.add(path);
      return null;
    }

    final baseErr = await addWorktree('base');
    if (baseErr != null) throw ProveTestsException(baseErr);
    final basePath = worktrees.last;
    String? currentPath;
    if (checkCurrent) {
      final err = await addWorktree('current');
      if (err != null) throw ProveTestsException(err);
      currentPath = worktrees.last;
    }

    for (final path in carried) {
      _copyInto(repo, basePath, path);
    }
    if (currentPath != null) {
      for (final c in changes) {
        if (c.deleted) {
          final f = File(p.join(currentPath, c.path));
          if (f.existsSync()) f.deleteSync();
        } else {
          _copyInto(repo, currentPath, c.path);
        }
      }
    }

    Future<Map<String, SuiteRun>> runAll(String tree) async {
      final setupErrors = <String, String>{};
      for (final pkg in packages) {
        final err = await _prepare(
          tree,
          pkg,
          cfg.proveSetup,
          runner,
          pubGetTimeout,
        );
        if (err != null) setupErrors[pkg] = err;
      }
      final runs = <String, SuiteRun>{};
      for (final t in selected) {
        final pkg = packageOf[t];
        if (pkg == null) continue;
        if (setupErrors[pkg] case final err?) {
          runs[t] = SuiteRun(tests: const [], setupError: err);
          continue;
        }
        runs[t] = await _runTestFile(tree, pkg, t, runner, timeout);
      }
      return runs;
    }

    final results = await Future.wait([
      runAll(basePath),
      if (currentPath != null) runAll(currentPath),
    ]);
    final baseRuns = results[0];
    final currentRuns = currentPath != null ? results[1] : null;

    final files = <FileResult>[];
    for (final t in selected) {
      final pkg = packageOf[t];
      if (pkg == null) {
        files.add(
          FileResult(
            file: t,
            packageDir: null,
            runner: null,
            verdicts: [
              TestVerdict(
                name: null,
                verdict: Verdict.inconclusive,
                detail: 'No pubspec.yaml found above this file.',
              ),
            ],
          ),
        );
        continue;
      }
      final isFlutter = _isFlutterPackage(p.join(repo, pkg));
      var verdicts = classify(baseRuns[t]!, currentRuns?[t]);
      String? note;
      if (verdicts.isEmpty) {
        note = 'The runner reported no tests in this file.';
        verdicts = [
          TestVerdict(name: null, verdict: Verdict.inconclusive, detail: note),
        ];
      }
      if (!Directory(p.join(basePath, pkg)).existsSync() ||
          !File(p.join(basePath, pkg, 'pubspec.yaml')).existsSync()) {
        note = 'The package did not exist at $baseRef.';
      }
      files.add(
        FileResult(
          file: t,
          packageDir: pkg,
          runner: isFlutter ? 'flutter' : 'dart',
          verdicts: verdicts,
          note: note,
        ),
      );
    }

    return ProveTestsReport(
      repoRoot: repo,
      baseRef: baseRef,
      baseSha: sha,
      checkCurrent: checkCurrent,
      files: files,
      carriedFiles: [
        for (final c in carried)
          if (!selected.contains(c)) c,
      ]..sort(),
    );
  } finally {
    for (final w in worktrees) {
      await git(['worktree', 'remove', '--force', w], cwd: repo);
    }
    await _deleteWithRetry(temp);
    await git(['worktree', 'prune'], cwd: repo);
  }
}

List<_Change> _parseNameStatus(String out) {
  final parts = out.split('\x00');
  final changes = <_Change>[];
  for (var i = 0; i + 1 < parts.length; i += 2) {
    final status = parts[i].trim();
    final path = parts[i + 1];
    if (status.isEmpty || path.isEmpty) continue;
    changes.add(_Change(path, deleted: status.startsWith('D')));
  }
  return changes;
}

void _copyInto(String repo, String tree, String rel) {
  final src = File(p.join(repo, rel));
  if (!src.existsSync()) return;
  final dst = File(p.join(tree, rel));
  dst.parent.createSync(recursive: true);
  src.copySync(dst.path);
}

bool _isFlutterPackage(String dir) {
  try {
    return Pubspec.load(dir).isFlutter;
  } on Object {
    return false;
  }
}

/// Runs `pub get` (at the workspace root for workspace members) and any
/// configured setup commands. Returns an error message, or null.
Future<String?> _prepare(
  String tree,
  String pkg,
  List<List<String>> setup,
  CommandRunner runner,
  Duration timeout,
) async {
  final pkgDir = p.join(tree, pkg);
  if (!File(p.join(pkgDir, 'pubspec.yaml')).existsSync()) {
    return 'no pubspec.yaml at $pkg in this tree';
  }
  final pubspec = Pubspec.load(pkgDir);
  var pubDir = pkgDir;
  if (pubspec.isWorkspaceMember) {
    var dir = p.dirname(pkgDir);
    while (p.isWithin(tree, dir) || p.equals(tree, dir)) {
      final f = File(p.join(dir, 'pubspec.yaml'));
      if (f.existsSync() && Pubspec.load(dir).raw['workspace'] != null) {
        pubDir = dir;
        break;
      }
      if (p.equals(tree, dir)) break;
      dir = p.dirname(dir);
    }
  }
  final tool = pubspec.isFlutter ? 'flutter' : 'dart';
  final get = await runner(
    [tool, 'pub', 'get'],
    workingDirectory: pubDir,
    timeout: timeout,
  );
  if (!get.succeeded) {
    return '`$tool pub get` failed: ${trimOutput(get.combinedOutput, maxLines: 15)}';
  }
  for (final cmd in setup) {
    final r = await runner(cmd, workingDirectory: pkgDir, timeout: timeout);
    if (!r.succeeded) {
      return 'setup command `${cmd.join(' ')}` failed: '
          '${trimOutput(r.combinedOutput, maxLines: 15)}';
    }
  }
  return null;
}

Future<SuiteRun> _runTestFile(
  String tree,
  String pkg,
  String testRel,
  CommandRunner runner,
  Duration timeout,
) async {
  final pkgDir = p.join(tree, pkg);
  final isFlutter = _isFlutterPackage(pkgDir);
  final testPath = p.relative(p.join(tree, testRel), from: pkgDir);
  final command = isFlutter
      ? ['flutter', 'test', '--no-pub', '--reporter', 'json', testPath]
      : ['dart', 'test', '--reporter', 'json', testPath];
  final outcome = await runner(
    command,
    workingDirectory: pkgDir,
    timeout: timeout,
  );
  if (outcome.timedOut) {
    return SuiteRun(tests: const [], timedOut: true);
  }
  if (outcome.startError != null) {
    return SuiteRun(tests: const [], setupError: outcome.startError);
  }
  return parseJsonReporter(outcome.stdout, stderr: outcome.stderr);
}

Future<void> _deleteWithRetry(Directory dir) async {
  for (var attempt = 0; attempt < 5; attempt++) {
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      return;
    } on FileSystemException {
      // Windows keeps files locked briefly after a process exits.
      await Future<void>.delayed(Duration(milliseconds: 300 * (attempt + 1)));
    }
  }
}

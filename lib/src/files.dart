import 'dart:io';

import 'package:path/path.dart' as p;

/// Directory names that never contain hand-written source worth scanning.
const skippedDirNames = <String>{
  '.dart_tool',
  'build',
  '.git',
  '.idea',
  '.vscode',
  '.symlinks',
  'Pods',
  'node_modules',
  'ephemeral',
};

bool _skipDir(String name) =>
    skippedDirNames.contains(name) || name.startsWith('.');

/// Converts [path] to a forward-slash path relative to [root].
String relPosix(String root, String path) =>
    p.relative(path, from: root).replaceAll(r'\', '/');

/// Lists files under [dir] (recursively) whose names satisfy [accept],
/// skipping build output, tool caches and hidden directories.
///
/// Directories in [stopAt] (absolute, normalized) are not descended into;
/// that is how a monorepo scan keeps a nested package's files out of its
/// parent.
List<File> listFiles(
  String dir, {
  required bool Function(String name) accept,
  Set<String> stopAt = const {},
}) {
  final out = <File>[];
  void walk(Directory d) {
    List<FileSystemEntity> children;
    try {
      children = d.listSync(followLinks: false);
    } on FileSystemException {
      return;
    }
    for (final e in children) {
      final name = p.basename(e.path);
      if (e is Directory) {
        if (_skipDir(name)) continue;
        if (stopAt.contains(p.normalize(e.absolute.path))) continue;
        walk(e);
      } else if (e is File && accept(name)) {
        out.add(e);
      }
    }
  }

  final root = Directory(dir);
  if (root.existsSync()) walk(root);
  out.sort((a, b) => a.path.compareTo(b.path));
  return out;
}

/// Lists `.dart` files under [dir]. See [listFiles].
List<File> dartFilesUnder(String dir, {Set<String> stopAt = const {}}) =>
    listFiles(dir, accept: (n) => n.endsWith('.dart'), stopAt: stopAt);

/// Finds every directory under [root] (including [root]) that holds a
/// `pubspec.yaml`, skipping build output and hidden directories.
List<String> findPackageDirs(String root) {
  final pubspecs = listFiles(root, accept: (n) => n == 'pubspec.yaml');
  return [for (final f in pubspecs) p.normalize(p.dirname(f.absolute.path))]
    ..sort();
}

/// Walks up from [start] (a file or directory) to the nearest directory that
/// holds a `pubspec.yaml`, not going above [limit]. Returns null if none.
String? nearestPackageDir(String start, {required String limit}) {
  var dir = p.normalize(
    FileSystemEntity.isDirectorySync(start) ? start : p.dirname(start),
  );
  final stop = p.normalize(limit);
  while (true) {
    if (File(p.join(dir, 'pubspec.yaml')).existsSync()) return dir;
    if (p.equals(dir, stop) || !p.isWithin(stop, dir)) return null;
    final parent = p.dirname(dir);
    if (parent == dir) return null;
    dir = parent;
  }
}

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Creates a temporary directory that is deleted after the current test.
String tempDir([String prefix = 'dvm_test_']) {
  final dir = Directory.systemTemp.createTempSync(prefix);
  addTearDown(() async {
    for (var i = 0; i < 5; i++) {
      try {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
        return;
      } on FileSystemException {
        await Future<void>.delayed(Duration(milliseconds: 200 * (i + 1)));
      }
    }
  });
  return dir.path;
}

/// Writes each `path: contents` entry under [root], creating directories.
void writeFiles(String root, Map<String, String> files) {
  files.forEach((rel, contents) {
    final f = File(p.join(root, rel));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(contents);
  });
}

/// Writes a `.dart_tool/package_config.json` for [root] mapping each name to
/// a directory (absolute path).
void writePackageConfig(String root, Map<String, String> packages) {
  final entries = packages.entries
      .map(
        (e) =>
            '{"name": "${e.key}", "rootUri": "${Uri.directory(e.value)}", '
            '"packageUri": "lib/"}',
      )
      .join(',\n');
  writeFiles(root, {
    '.dart_tool/package_config.json':
        '{"configVersion": 2, "packages": [$entries]}',
  });
}

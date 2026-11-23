/// A small, dependency-free scanner for the parts of Dart source this tool
/// needs: `import`/`export`/`part` directives, and the source with comments
/// removed.
///
/// It is deliberately not a full parser. It understands exactly enough of the
/// lexical grammar to avoid the two classic mistakes of a regex-per-line
/// approach: matching an `import` that sits inside a comment or a string, and
/// missing a directive that is split across lines or has conditional
/// configurations (`if (dart.library.io) 'io.dart'`).
library;

/// The kind of a URI-bearing directive.
enum DirectiveKind { import, export, part }

/// One URI referenced by a directive.
///
/// A conditional import produces one [DirectiveUri] for the default URI and
/// one per configuration, so that a rule forbidding `dart:io` also catches
/// `if (dart.library.io) 'dart:io'`.
class DirectiveUri {
  DirectiveUri({
    required this.kind,
    required this.uri,
    required this.line,
    required this.directiveLine,
    this.condition,
  });

  final DirectiveKind kind;

  /// The URI exactly as written between the quotes.
  final String uri;

  /// 1-based line of the string literal holding [uri].
  final int line;

  /// 1-based line of the `import`/`export`/`part` keyword.
  final int directiveLine;

  /// For a configuration URI, the condition text, e.g. `dart.library.io`.
  /// Null for the directive's default URI.
  final String? condition;

  bool get isConditional => condition != null;

  @override
  String toString() =>
      '${kind.name} $uri (line $line${condition == null ? '' : ', if $condition'})';
}

enum _TokenType { identifier, string, punct }

class _Token {
  _Token(this.type, this.text, this.line);
  final _TokenType type;

  /// For identifiers and punctuation, the lexeme. For strings, the contents
  /// between the quotes (escapes are not decoded; URIs do not need them).
  final String text;
  final int line;
}

class _Lexer {
  _Lexer(this.src);

  final String src;
  int pos = 0;
  int line = 1;
  final tokens = <_Token>[];

  /// The source with every comment character replaced by a space, so line
  /// and column positions are preserved.
  final StringBuffer stripped = StringBuffer();

  bool get atEnd => pos >= src.length;
  String peek([int ahead = 0]) =>
      pos + ahead < src.length ? src[pos + ahead] : '';

  void _advance({bool keep = true}) {
    final c = src[pos];
    if (c == '\n') {
      line++;
      stripped.write('\n');
    } else {
      stripped.write(keep ? c : (c == '\r' ? '\r' : ' '));
    }
    pos++;
  }

  void run() {
    _lexCode(stopAtBrace: false);
  }

  /// Lexes code until end of input, or until an unmatched `}` when
  /// [stopAtBrace] is set (used for `${...}` interpolations).
  void _lexCode({required bool stopAtBrace}) {
    var depth = 0;
    while (!atEnd) {
      final c = peek();
      if (c == '/' && peek(1) == '/') {
        while (!atEnd && peek() != '\n') {
          _advance(keep: false);
        }
        continue;
      }
      if (c == '/' && peek(1) == '*') {
        _skipBlockComment();
        continue;
      }
      if (_isStringStart()) {
        _lexString(emit: !stopAtBrace);
        continue;
      }
      if (_isIdentStart(c)) {
        final start = pos;
        final startLine = line;
        while (!atEnd && _isIdentPart(peek())) {
          _advance();
        }
        if (!stopAtBrace) {
          tokens.add(
            _Token(_TokenType.identifier, src.substring(start, pos), startLine),
          );
        }
        continue;
      }
      if (c == '{') {
        depth++;
      } else if (c == '}') {
        if (stopAtBrace && depth == 0) {
          _advance();
          return;
        }
        depth--;
      }
      if (!stopAtBrace && !_isWhitespace(c)) {
        tokens.add(_Token(_TokenType.punct, c, line));
      }
      _advance();
    }
  }

  void _skipBlockComment() {
    // Dart block comments nest.
    var depth = 0;
    while (!atEnd) {
      if (peek() == '/' && peek(1) == '*') {
        depth++;
        _advance(keep: false);
        _advance(keep: false);
        continue;
      }
      if (peek() == '*' && peek(1) == '/') {
        depth--;
        _advance(keep: false);
        _advance(keep: false);
        if (depth == 0) return;
        continue;
      }
      _advance(keep: false);
    }
  }

  bool _isStringStart() {
    final c = peek();
    if (c == '"' || c == "'") return true;
    if ((c == 'r' || c == 'R') && (peek(1) == '"' || peek(1) == "'")) {
      // Only a raw-string prefix if `r` is not the tail of an identifier,
      // which the identifier branch would already have consumed.
      return true;
    }
    return false;
  }

  void _lexString({required bool emit}) {
    final startLine = line;
    var raw = false;
    if (peek() == 'r' || peek() == 'R') {
      raw = true;
      _advance();
    }
    final quote = peek();
    final triple = peek(1) == quote && peek(2) == quote;
    final delimiter = triple ? quote * 3 : quote;
    for (var i = 0; i < delimiter.length; i++) {
      _advance();
    }
    final content = StringBuffer();
    while (!atEnd) {
      if (src.startsWith(delimiter, pos)) {
        for (var i = 0; i < delimiter.length; i++) {
          _advance();
        }
        break;
      }
      final c = peek();
      if (!triple && c == '\n') break; // Unterminated; recover at newline.
      if (!raw && c == r'\') {
        content.write(c);
        _advance();
        if (!atEnd) {
          content.write(peek());
          _advance();
        }
        continue;
      }
      if (!raw && c == r'$' && peek(1) == '{') {
        content.write(r'${');
        _advance();
        _advance();
        _lexCode(stopAtBrace: true);
        content.write('}');
        continue;
      }
      content.write(c);
      _advance();
    }
    if (emit) {
      tokens.add(_Token(_TokenType.string, content.toString(), startLine));
    }
  }

  static bool _isWhitespace(String c) =>
      c == ' ' || c == '\t' || c == '\n' || c == '\r';

  static bool _isIdentStart(String c) {
    final u = c.codeUnitAt(0);
    return (u >= 0x41 && u <= 0x5A) ||
        (u >= 0x61 && u <= 0x7A) ||
        u == 0x5F ||
        u == 0x24;
  }

  static bool _isIdentPart(String c) {
    if (c.isEmpty) return false;
    final u = c.codeUnitAt(0);
    return _isIdentStart(c) || (u >= 0x30 && u <= 0x39);
  }
}

/// Returns [source] with all comments replaced by spaces. Strings are kept.
/// Line numbers are preserved, so a match at line N of the result is at
/// line N of the original.
String stripComments(String source) {
  final lexer = _Lexer(source)..run();
  return lexer.stripped.toString();
}

/// Extracts every URI referenced by an `import`, `export` or `part` directive
/// in [source], including the URIs of conditional configurations.
///
/// `part of` directives are ignored: they name the owning library rather than
/// a dependency.
List<DirectiveUri> parseDirectives(String source) {
  final lexer = _Lexer(source)..run();
  final tokens = lexer.tokens;
  final result = <DirectiveUri>[];

  for (var i = 0; i < tokens.length; i++) {
    final t = tokens[i];
    if (t.type != _TokenType.identifier) continue;
    final DirectiveKind kind;
    switch (t.text) {
      case 'import':
        kind = DirectiveKind.import;
      case 'export':
        kind = DirectiveKind.export;
      case 'part':
        kind = DirectiveKind.part;
      default:
        continue;
    }
    // A directive keyword is followed directly by the URI string. That shape
    // does not occur anywhere else in valid Dart, so it is a sufficient test
    // without tracking whether we are still in the directive section.
    if (i + 1 >= tokens.length || tokens[i + 1].type != _TokenType.string) {
      continue;
    }
    // Reject `foo.import 'x'`-like shapes (not valid Dart anyway) and member
    // access such as `x.part`, which would precede a string only in invalid
    // code but costs nothing to guard against.
    if (i > 0 &&
        tokens[i - 1].type == _TokenType.punct &&
        tokens[i - 1].text == '.') {
      continue;
    }
    final uriTok = tokens[i + 1];
    result.add(
      DirectiveUri(
        kind: kind,
        uri: uriTok.text,
        line: uriTok.line,
        directiveLine: t.line,
      ),
    );
    if (kind == DirectiveKind.part) continue;

    // Configurations: if ( dotted.name [== 'value'] ) 'uri'
    var j = i + 2;
    // Skip adjacent string literals that continue the URI (rare).
    while (j < tokens.length && tokens[j].type == _TokenType.string) {
      j++;
    }
    while (j < tokens.length) {
      final tok = tokens[j];
      if (tok.type == _TokenType.punct && tok.text == ';') break;
      if (tok.type == _TokenType.identifier &&
          tok.text == 'if' &&
          j + 1 < tokens.length &&
          tokens[j + 1].text == '(') {
        final cond = StringBuffer();
        var k = j + 2;
        while (k < tokens.length && tokens[k].text != ')') {
          final ct = tokens[k];
          cond.write(ct.type == _TokenType.string ? "'${ct.text}'" : ct.text);
          k++;
        }
        if (k + 1 < tokens.length && tokens[k + 1].type == _TokenType.string) {
          final u = tokens[k + 1];
          result.add(
            DirectiveUri(
              kind: kind,
              uri: u.text,
              line: u.line,
              directiveLine: t.line,
              condition: cond.toString().replaceAll('==', ' == '),
            ),
          );
          j = k + 2;
          continue;
        }
        j = k + 1;
        continue;
      }
      // `as prefix`, `show a, b`, `hide c`, `deferred` and their identifiers
      // are skipped until the terminating semicolon.
      j++;
    }
  }
  return result;
}

/// The package name referenced by a `package:` URI, or null.
String? packageNameOf(String uri) {
  if (!uri.startsWith('package:')) return null;
  final rest = uri.substring('package:'.length);
  final slash = rest.indexOf('/');
  if (slash <= 0) return null;
  return rest.substring(0, slash);
}

/// Verification checks for coding agents working on Dart and Flutter
/// projects, exposed as an MCP server and usable as a library.
library;

export 'src/dart_source.dart'
    show
        DirectiveKind,
        DirectiveUri,
        packageNameOf,
        parseDirectives,
        stripComments;

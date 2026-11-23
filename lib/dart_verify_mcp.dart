/// Verification checks for coding agents working on Dart and Flutter
/// projects, exposed as an MCP server and usable as a library.
library;

export 'src/config.dart'
    show
        CodePattern,
        ConfigException,
        GateStep,
        LayerRule,
        VerifyConfig,
        configFileName,
        splitCommand;
export 'src/dart_source.dart'
    show
        DirectiveKind,
        DirectiveUri,
        packageNameOf,
        parseDirectives,
        stripComments;
export 'src/layers.dart'
    show LayerReport, LayerViolation, checkLayers, uriMatches;
export 'src/unused_deps.dart'
    show
        DepFinding,
        DepStatus,
        PackageDepReport,
        UnusedDepsReport,
        findUnusedDependencies;

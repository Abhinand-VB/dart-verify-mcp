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
export 'src/gate.dart'
    show GateReport, StepResult, StepStatus, defaultSteps, runGate;
export 'src/layers.dart'
    show LayerReport, LayerViolation, checkLayers, uriMatches;
export 'src/process_runner.dart'
    show CommandRunner, ProcessOutcome, runCommand, trimOutput;
export 'src/prove_tests.dart'
    show FileResult, ProveTestsException, ProveTestsReport, proveTestsCanFail;
export 'src/server.dart' show VerifyServer, packageVersion;
export 'src/test_results.dart'
    show
        SuiteRun,
        TestOutcome,
        TestVerdict,
        Verdict,
        classify,
        parseJsonReporter;
export 'src/unused_deps.dart'
    show
        DepFinding,
        DepStatus,
        PackageDepReport,
        UnusedDepsReport,
        findUnusedDependencies;

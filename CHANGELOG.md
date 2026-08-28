# Changelog

All notable changes to swift-process-kernel are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- DocC catalogue for `ProcessKernel` with a landing page covering the three ways
  `Foundation.Process` can wait forever, what the deadline does about descendants,
  and why the timeout returns exit code `124` rather than throwing.
- `.quality-gate.yml` declaring `boundedIO.kernelPath`. This package *is* the
  bounded-IO kernel, but the checker's default path still names the file's old home
  in `QualityGateCore` — so undeclared, the rule told `ProcessRunner.swift` to
  "spawn through ProcessRunner", i.e. to route through itself.

## [1.0.0] — 2026-08-27

### Added

- `ProcessRunner`, extracted from quality-gate-swift, where it could not be shared:
  anything wanting it had to depend on the whole gate, and quality-gate-swift
  depends on swift-vigil, so vigil adopting it would have closed a dependency
  cycle. Nothing in it is quality-gate-specific — it answers a Foundation problem.
- `ProcessRunnerDeadlineTests` and `ProcessRunnerStdinTests`, the corpus of hang
  variants found so far: an inherited write end that kept a read waiting 46
  minutes, a `swift-test` grandchild that outlived its parent by 6h55m, and a
  dispatch-pool starvation indistinguishable from the pipe deadlock the concurrent
  readers exist to prevent. That corpus is why this is a package rather than a
  snippet worth copying.

[Unreleased]: https://github.com/jpurnell/swift-process-kernel/compare/1.0.0...HEAD
[1.0.0]: https://github.com/jpurnell/swift-process-kernel/releases/tag/1.0.0

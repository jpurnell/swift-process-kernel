# Changelog

All notable changes to swift-process-kernel are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.1.0] — 2026-10-06

Prepared as 1.0.1 and released as 1.1.0: it adds public API (`ProcessRunner.InvalidTimeout`,
`ProcessRunner.maximumTimeout`) and a non-finite timeout now throws where it used to wait
with no deadline, which is more than a patch.

### Fixed

- `ProcessRunner.run` no longer has a timeout that means *no deadline*, or one that stops
  the process. `timeout` is a caller-supplied `TimeInterval`, and three kinds of value went
  through unexamined: a NaN, an infinity, and anything past ~292 years. `DispatchTime +
  Double` saturates all three to `DISPATCH_TIME_FOREVER`, so the runner waited with no
  deadline at all — and had such a wait ever ended in a timeout, the `Int(timeout)` that
  formats the note would have trapped (`fallback.int-conversion-unguarded`). Each input now
  has an answer that was chosen:

  | `timeout` | What happens |
  | :--- | :--- |
  | NaN | throws `ProcessRunner.InvalidTimeout.notANumber`; nothing is spawned |
  | `+infinity`, `-infinity` | throws `.infinite`; nothing is spawned |
  | finite, greater than `ProcessRunner.maximumTimeout` (1e9 s) | throws `.exceedsMaximum(value)`; nothing is spawned |
  | zero or negative | a budget already spent: the child is started and terminated at once, exit code 124 — unchanged — and the note now reads `timed out after 0s — its budget of -5.0s was already spent —` |
  | fractional | unchanged, except the note reports `0.5s` where it used to truncate to `0s` |
  | whole and positive | unchanged, including the wording of the note |

  Nothing is clamped. A refusal is thrown before `Process.run()`, so there is no child to
  clean up.

  **One behaviour a caller could have been relying on:** `timeout: .infinity` (or
  `.greatestFiniteMagnitude`) used to work as "no deadline", by accident of the saturation
  above. It now throws. That is deliberate — a run that cannot be bounded is the thing this
  package exists to rule out — and none of the packages that depend on this one pass such a
  value, but it is a change in what a previously-working call does.

### Added

- `ProcessRunner.InvalidTimeout` and `ProcessRunner.maximumTimeout`, the public names the
  fix above needs. They are additions to the API in what is otherwise a patch.

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

[Unreleased]: https://github.com/jpurnell/swift-process-kernel/compare/1.1.0...HEAD
[1.1.0]: https://github.com/jpurnell/swift-process-kernel/compare/1.0.0...1.1.0
[1.0.0]: https://github.com/jpurnell/swift-process-kernel/releases/tag/1.0.0

# ``ProcessKernel``

A subprocess runner that cannot hang.

## Overview

`Foundation.Process` offers three ways to wait forever, and production code finds
all of them:

| Primitive | How it hangs |
| :--- | :--- |
| `readDataToEndOfFile()` | Returns at EOF, and EOF waits on *every* inherited write end — including a grandchild's, long after the child exited. |
| `waitUntilExit()` | Returns when the child exits, or never. |
| Sequential pipe reads | The child blocks writing to a full stderr buffer (~64 KB) while the caller blocks reading stdout. |

``ProcessRunner/run(_:arguments:currentDirectory:environment:stdin:mergeStderr:timeout:)``
closes all three. Every behaviour in it was written in response to a specific
incident, and the source names them: a 46-minute silent hang on a write end the
parent still held, an orphaned `swift-test` that outlived its parent by 6h55m and
kept the pipe open, and a dispatch-pool starvation that presented exactly as the
pipe deadlock the concurrent readers exist to prevent.

```swift
import Foundation
import ProcessKernel

let root = FileManager.default.currentDirectoryPath

let result = try ProcessRunner.run(
    "/usr/bin/env",
    arguments: ["echo", "hello"],
    currentDirectory: root,
    mergeStderr: true,
    timeout: 30
)

// 124 is the timeout code, the convention GNU `timeout` uses.
print(result.exitCode == 124 ? "timed out" : result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
```

## What the deadline actually does

Signalling the child is not enough. `Process` spawns the child as leader of a
fresh process group, and a group outlives its leader — so a grandchild can hold
the pipe open after the child is gone, and `terminate()` on an exited child is a
no-op. The deadline signals the *group*, then escalates to `SIGKILL`.

Output is read incrementally rather than at EOF, so a run that times out still
returns what the child managed to produce. That is usually the best evidence
about why it hung, and the ordering matters: snapshotting after the kill would
discard exactly the output that explains the failure.

A timeout returns exit code `124` — the convention GNU `timeout` uses — with a
note appended to stderr, rather than throwing. A caller reading only the status
can still tell a timeout from an ordinary failure.

## This package is its own bounded-IO kernel

The unbounded primitives above live in `ProcessRunner.swift` and nowhere else,
which is what `.quality-gate.yml` declares via `boundedIO.kernelPath`. Confining
them is checkable; proving any particular wait is bounded is not.

## Topics

### Running a process

- ``ProcessRunner``
- ``ProcessRunner/Output``

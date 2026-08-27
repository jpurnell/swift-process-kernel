# swift-process-kernel

A subprocess runner that cannot hang.

`Foundation.Process` gives you three ways to wait forever, and production code
finds all of them:

| Primitive | How it hangs |
| :--- | :--- |
| `readDataToEndOfFile()` | Returns at EOF. EOF waits on *every* inherited write end — including a grandchild's, long after the child exits. |
| `waitUntilExit()` | Returns when the child exits, or never. |
| Sequential pipe reads | The child blocks writing to a full stderr buffer (~64 KB) while you block reading stdout. |

`ProcessRunner.run` closes all three:

```swift
import ProcessKernel

let result = try ProcessRunner.run(
    "/usr/bin/env",
    arguments: ["swift", "test"],
    currentDirectory: root,
    mergeStderr: true,
    timeout: 1_800
)
result.exitCode == 124   // timed out and was terminated
```

## What it actually does

- **Reads both pipes concurrently**, on dedicated `Thread`s rather than a dispatch
  queue — a blocked wait on a libdispatch worker can starve the pool before the
  reader blocks are ever scheduled, which looks exactly like the deadlock it is
  supposed to prevent.
- **Closes its own copies of the write ends** after spawning. Leaving them open
  means a child that spawns a grandchild can exit while the descriptor lives on,
  and the read waits forever.
- **Signals the process *group*** at the deadline, not just the child. `Process`
  spawns the child as leader of a fresh group, and a group outlives its leader,
  so this reaches descendants when the child is already gone.
- **Reads incrementally**, so a run that times out still returns the output the
  child managed to produce — usually the best evidence about why it hung.
- **Disarms SIGPIPE once** before writing a stdin payload. Writing to a pipe whose
  reader has gone raises SIGPIPE, whose default disposition *terminates the
  process*, and no `try?` intercepts it.

Timeouts return exit code 124 — the convention GNU `timeout` uses — with a note
appended to stderr, rather than throwing. A caller reading only the code can
still tell a timeout from an ordinary failure.

## Provenance

Extracted from `quality-gate-swift`, where each of the behaviours above was
written in response to a specific incident: a 46-minute silent hang on an
inherited descriptor, an orphaned `swift-test` that outlived its parent by
6h55m, and a dispatch-pool starvation that mimicked the pipe deadlock. The
tests in `ProcessRunnerDeadlineTests` are a corpus of every hang variant found
so far; they are the reason this is a package rather than a snippet worth
copying.

## Requirements

macOS 14+, Swift 6.2+. No dependencies.

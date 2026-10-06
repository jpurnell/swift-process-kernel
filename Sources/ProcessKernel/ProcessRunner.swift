import Foundation
import Synchronization

/// Accumulates a reader thread's output.
///
/// A plain reference type with a lock, rather than `Mutex<Data>`: the readers run on escaping
/// closures, and a noncopyable value captured there does not reliably reach the same instance —
/// appends went to a copy and the captured output came back empty. A class has one identity,
/// which is the property this needs.
// Justification: `data` is only ever touched under `lock`, and the class holds no other state.
private final class OutputBox: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
    }

    func snapshot() -> Data {
        lock.lock(); defer { lock.unlock() }
        return data
    }
}

/// Runs a child process and captures its output without pipe-buffer deadlocks.
///
/// Foundation's `Process` with `Pipe` can deadlock when the child process
/// produces more output than the pipe buffer (~64 KB). Reading stdout then
/// stderr sequentially blocks if the child fills stderr before closing
/// stdout — the child blocks on stderr write while the caller blocks
/// waiting for stdout EOF.
///
/// This helper reads stdout and stderr concurrently on background threads,
/// then waits for the process to finish.
public enum ProcessRunner: Sendable {

    /// Result of running a process.
    public struct Output: Sendable {
        /// Combined or individual stdout content.
        public let stdout: String
        /// stderr content (empty if merged with stdout).
        public let stderr: String
        /// Process exit code.
        public let exitCode: Int32
    }

    /// A timeout ``run(_:arguments:currentDirectory:environment:stdin:mergeStderr:timeout:)``
    /// will not act on.
    ///
    /// Each of these, passed through, would have meant *no deadline*: `DispatchTime + Double`
    /// saturates a NaN, an infinity and anything past ~292 years to `DISPATCH_TIME_FOREVER`.
    /// A runner whose purpose is the deadline does not quietly run without one, and it does not
    /// quietly substitute a different deadline either — so the caller is told, before the
    /// child is started.
    ///
    /// Zero and negative timeouts are **not** here. They are a budget already spent, and are
    /// answered with exit code 124.
    public enum InvalidTimeout: Error, Equatable, Sendable, CustomStringConvertible {
        /// The timeout was a NaN — usually `0 / 0` or an uninitialised measurement upstream.
        case notANumber
        /// The timeout was `+infinity` or `-infinity`.
        case infinite
        /// The timeout was finite but past ``ProcessRunner/maximumTimeout``. Carries the value
        /// that was passed.
        case exceedsMaximum(TimeInterval)

        /// What was wrong, and that nothing was run.
        public var description: String {
            switch self {
            case .notANumber:
                return "process-kernel: the timeout is not a number. Nothing was run."
            case .infinite:
                return "process-kernel: the timeout is infinite, and a run with no deadline is the one thing this runner does not offer. Nothing was run."
            case .exceedsMaximum(let timeout):
                return "process-kernel: the timeout of \(timeout)s is past the maximum of \(ProcessRunner.maximumTimeout)s. Nothing was run."
            }
        }
    }

    /// The longest timeout accepted: one billion seconds, a little under 32 years.
    ///
    /// The bound exists because the deadline is kept as nanoseconds in an `Int64`, which runs
    /// out near 9.2 billion seconds; past that, dispatch treats the wait as unbounded. One
    /// billion is the round figure safely inside it. Nothing legitimately waits this long — it
    /// is the line between a long deadline and no deadline at all.
    public static let maximumTimeout: TimeInterval = 1_000_000_000

    /// Refuses a timeout that would mean no deadline.
    ///
    /// - Parameter timeout: The caller's wall-clock budget, in seconds.
    /// - Throws: ``InvalidTimeout`` for a NaN, an infinity, or a value past ``maximumTimeout``.
    private static func validate(timeout: TimeInterval) throws {
        guard !timeout.isNaN else { throw InvalidTimeout.notANumber }
        guard timeout.isFinite else { throw InvalidTimeout.infinite }
        guard timeout <= maximumTimeout else { throw InvalidTimeout.exceedsMaximum(timeout) }
    }

    /// How long a timed-out run was allowed, as the timeout note words it.
    ///
    /// - Parameter timeout: A timeout that ``validate(timeout:)`` has already accepted.
    /// - Returns: `"30s"` for a whole number of seconds and `"0.5s"` for a fractional one —
    ///   the figure as given, never truncated. For zero or a negative timeout, `"0s"` followed
    ///   by the budget that was passed, since no time was allowed and the caller should see why.
    private static func elapsedDescription(of timeout: TimeInterval) -> String {
        guard timeout > 0 else {
            return "0s — its budget of \(timeout)s was already spent —"
        }
        // `maximumTimeout` is far inside Int's range, so a whole value in bounds converts
        // exactly; anything else — a fraction — is printed as the Double it is.
        guard timeout <= maximumTimeout, let whole = Int(exactly: timeout) else {
            return "\(timeout)s"
        }
        return "\(whole)s"
    }

    /// Disarms SIGPIPE, once, before the first stdin payload is written.
    ///
    /// Writing to a pipe whose reader has gone raises SIGPIPE, and its default disposition
    /// **terminates the process** — the signal arrives before the syscall can return an error, so
    /// no amount of `try?` intercepts it. A child that exits without reading its input is an
    /// ordinary thing (`sh -c "echo done"` does it), and it must not be able to kill the gate.
    ///
    /// Found by the test written for exactly this case: the suite died with signal 13 rather than
    /// failing an expectation, which is what a process-wide signal looks like from the outside.
    ///
    /// Changing global signal disposition from a library is a real side effect and is not done
    /// lightly. The alternative is worse: every caller passing `stdin` inherits a way to be killed
    /// by a well-behaved child. Ignoring SIGPIPE turns it into `EPIPE` on the write, which is a
    /// value the code above already handles.
    private static let sigpipeIgnored: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()

    /// Runs a process with the given executable and arguments.
    ///
    /// - Parameters:
    ///   - executablePath: Absolute path to the executable.
    ///   - arguments: Command-line arguments.
    ///   - currentDirectory: Working directory (nil for inherited).
    ///   - environment: Full environment for the child (nil inherits the parent's).
    ///     Pass an explicit environment to isolate a child from inherited state —
    ///     e.g. scrubbing `GIT_*` vars so a `git` subprocess ignores an ambient
    ///     repository set by a git hook.
    ///   - stdin: Payload written to the child's standard input, then closed so the child sees
    ///     EOF. Written on its own thread: a payload past the ~64 KB pipe buffer blocks until the
    ///     child drains it, and a child that reads to EOF before replying would never drain.
    ///   - mergeStderr: If true, stderr is merged into stdout.
    ///   - timeout: Wall-clock budget. On expiry the child is terminated, whatever output
    ///     arrived is returned, and `exitCode` is non-zero with the timeout named in `stderr` —
    ///     **a timeout is a finding, not a crash**, and the caller decides what it means. The
    ///     default is generous because a cold build of a large package legitimately takes
    ///     minutes; what it rules out is *forever*.
    ///
    ///     Zero or a negative number is a budget already spent — what
    ///     `deadline.timeIntervalSinceNow` returns once the deadline has passed. The child is
    ///     started and terminated at once, and the run reports exit code 124 like any other
    ///     timeout, with the figure that was passed named in `stderr`.
    ///
    ///     A NaN, an infinity, or anything past ``maximumTimeout`` is refused with
    ///     ``InvalidTimeout`` before the child is started. None of them is clamped: each would
    ///     otherwise mean *no deadline*.
    /// - Returns: The captured output and exit code.
    /// - Throws: ``InvalidTimeout`` if `timeout` is not a number, is infinite, or is past
    ///   ``maximumTimeout`` — thrown before anything is spawned. Otherwise whatever
    ///   `Process.run()` throws, typically because `executablePath` cannot be executed.
    public static func run(
        _ executablePath: String,
        arguments: [String] = [],
        currentDirectory: String? = nil,
        environment: [String: String]? = nil,
        stdin: Data? = nil,
        mergeStderr: Bool = false,
        timeout: TimeInterval = 600
    ) throws -> Output {
        // Judged before anything is spawned, so a refusal leaves nothing to clean up.
        try validate(timeout: timeout)

        let process = Process() // SAFETY: callers pass hardcoded executable paths
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        if let dir = currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: dir)
        }
        if let environment {
            process.environment = environment
        }

        // A stdin payload gets its own pipe, written on its own thread — see below.
        let stdinPipe: Pipe? = stdin == nil ? nil : Pipe()
        if let stdinPipe {
            process.standardInput = stdinPipe
        }

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe

        let stderrPipe: Pipe?
        if mergeStderr {
            process.standardError = stdoutPipe
            stderrPipe = nil
        } else {
            let p = Pipe()
            process.standardError = p
            stderrPipe = p
        }

        try process.run()

        // Close *our* copies of the write ends, now that the child owns them.
        //
        // `readDataToEndOfFile()` returns at EOF, and EOF arrives only when every write end is
        // closed — including the one this process still holds. Leaving it open means a child
        // that spawns a grandchild (SwiftPM does this routinely: build servers, test helpers,
        // index daemons) can exit while the descriptor lives on, and the read waits forever.
        // Observed 2026-08-16 as a 46-minute silent hang.
        try? stdoutPipe.fileHandleForWriting.close()  // silent: already closed if the child exited first, which is not an error
        if let stderrPipe {
            try? stderrPipe.fileHandleForWriting.close()  // silent: same
        }

        // The write runs on its own thread, and that is not tidiness.
        //
        // A pipe write blocks once the payload exceeds the ~64 KB buffer and stays blocked until
        // the child drains it. A child that reads its input to EOF before emitting anything —
        // the ordinary shape for a filter — will not drain until the write finishes. Writing
        // inline would therefore deadlock the two of us against each other: the mirror image of
        // the read-side hang this file already exists to prevent, and the bug `PluginRunner`
        // carries today by writing its payload on the calling thread.
        if let stdinPipe, let stdin {
            _ = Self.sigpipeIgnored
            Thread {
                let handle = stdinPipe.fileHandleForWriting
                // EPIPE when the child exits without reading is the child's choice, not a
                // failure of the run — the payload simply was not wanted.
                // silent: the child declined the input; that is its prerogative, not our error.
                try? handle.write(contentsOf: stdin)
                try? handle.close()  // silent: EOF is what ends a child that reads until it
            }.start()
        }

        // Read stdout and stderr concurrently to prevent pipe-buffer deadlock.
        // If either pipe's buffer fills (~64 KB) while the other is being read
        // sequentially, the child blocks on write and the caller blocks on read.
        let stdoutBox = OutputBox()
        let stderrBox = OutputBox()
        let readers = DispatchGroup()

        // Read incrementally rather than with `readDataToEndOfFile()`.
        //
        // That call accumulates internally and hands everything back at EOF, so a run that
        // times out returns *nothing* — including output the child had already produced and
        // which is usually the most useful evidence about why it hung. Appending each chunk as
        // it arrives means a terminated run still reports what it managed to say.
        // Readers run on dedicated `Thread`s, not on a dispatch queue.
        //
        // `readers.wait()` below blocks the calling thread. If the readers were queued onto
        // libdispatch's worker pool, that blocked thread would be *from the same pool* — and
        // under load (a parallel test suite, or several checkers running at once) the pool can
        // starve before the reader blocks are ever scheduled. The symptom is indistinguishable
        // from the pipe deadlock this helper exists to prevent: a run that produces no output
        // and ends exactly at its deadline. Measured while fixing that very bug.
        readers.enter()
        Thread {
            let handle = stdoutPipe.fileHandleForReading
            // silent: a closed handle ends the drain — the intended exit path on timeout.
            while let chunk = (try? handle.read(upToCount: 64 * 1024)) ?? nil, !chunk.isEmpty {
                stdoutBox.append(chunk)
            }
            readers.leave()
        }.start()

        if let stderrPipe {
            readers.enter()
            Thread {
                let handle = stderrPipe.fileHandleForReading
                // silent: a closed handle ends the drain — how a timed-out run stops this reader.
                while let chunk = (try? handle.read(upToCount: 64 * 1024)) ?? nil, !chunk.isEmpty {
                    stderrBox.append(chunk)
                }
                readers.leave()
            }.start()
        }

        // The deadline. Descriptor hygiene above fixes the cause we found; this bounds the ones
        // we have not — a child blocked on a lock, a network read with no timeout of its own, a
        // prompt waiting on stdin it will never get.
        var timedOut = false
        if readers.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            // Signal the child's process GROUP by id, not just the child. `Process` spawns the
            // child as leader of a fresh group, and a group outlives its leader — so this
            // reaches descendants even when the child exited long ago and only a grandchild
            // holds the pipe (the shape that leaked a `swift-test` orphan for 6h55m;
            // `terminate()` on an exited child is a no-op). A fresh child pid can never equal
            // this process's own pgid, so the negative-pid signal cannot strike the gate
            // itself; when the whole group is already gone it is ESRCH, a no-op.
            _ = kill(-process.processIdentifier, SIGTERM)
            // Belt-and-braces for the direct child in case the group signal found nothing —
            // preserves the pre-group behavior if Foundation ever stops group-spawning.
            if process.isRunning {
                process.terminate()
            }
            // Give the group a moment to die and release the descriptors, then stop waiting on
            // the readers regardless: a deadline that can itself hang is not a deadline.
            _ = readers.wait(timeout: .now() + 5)
            // The guarantee, for whatever ignored SIGTERM. ESRCH when everything is dead.
            _ = kill(-process.processIdentifier, SIGKILL)
        }

        if !timedOut {
            process.waitUntilExit()
        }

        if timedOut {
            // Unblock the readers *before* snapshotting. The child is gone, but a grandchild may
            // still hold a copy of the write end — nothing this process closes can force that
            // one shut, so a reader can sit on a pipe that never reaches EOF while data it has
            // already been sent waits unread in the buffer. Closing the read end ends the
            // blocked read, and the reader then drains what was buffered.
            //
            // Ordering is the whole point: snapshotting first returns an empty result and
            // discards exactly the output that explains the hang.
            try? stdoutPipe.fileHandleForReading.close()  // silent: unblocking a reader; a close error changes nothing
            try? stderrPipe?.fileHandleForReading.close()  // silent: same
            _ = readers.wait(timeout: .now() + 2)
        }

        let stdoutData = stdoutBox.snapshot()
        let stderrData = stderrBox.snapshot()
        let capturedStderr = String(data: stderrData, encoding: .utf8) ?? ""

        if timedOut {
            return Output(
                stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                stderr: capturedStderr
                    + "\nprocess-kernel: `\(executablePath)` timed out after \(elapsedDescription(of: timeout)) and was terminated.",
                // 124 is the conventional timeout exit code (GNU `timeout`), so a caller
                // reading only the code can still tell this apart from an ordinary failure.
                exitCode: 124
            )
        }

        return Output(
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: capturedStderr,
            exitCode: process.terminationStatus
        )
    }
}

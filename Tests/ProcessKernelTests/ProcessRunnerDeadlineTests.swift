import Foundation
import Testing
import ProcessKernel

/// Tests that `ProcessRunner` cannot wait forever.
///
/// Observed 2026-08-16: a survey run against `Alamofire` sat for **46 minutes** producing
/// nothing. `sample` showed the main thread parked and a `quality-gate.stderr-reader` thread
/// blocked in `readDataToEndOfFile()`, with no child process alive.
///
/// The runner already guards the classic 64 KB pipe-buffer deadlock — it reads stdout and
/// stderr concurrently, and its doc comment explains why. This is a different failure with the
/// same symptom: `readDataToEndOfFile()` returns at EOF, and EOF arrives only when *every*
/// write end closes. A child that spawns a grandchild passes the inherited descriptors along,
/// so the child can exit while the grandchild holds the pipe open — and the read never returns.
/// SwiftPM does this routinely.
///
/// This matters well beyond the survey: `ProcessRunner` is the shared path for `BuildChecker`,
/// `TestRunner`, `DocLinter`, `UnreachableCodeAuditor` and a dozen more, so a hang here hangs
/// the pre-commit hook — which already takes ~8 minutes, making an infinite hang nearly
/// indistinguishable from a slow run.
@Suite("ProcessRunner deadline")
struct ProcessRunnerDeadlineTests {

    /// **The reproduction**, and a correction to the first analysis of it.
    ///
    /// The child exits immediately; the grandchild inherits the pipe and holds it for 30
    /// seconds. Closing the *parent's* copy of the write end — the first fix attempted — does
    /// not help: the grandchild has its own inherited copy, and nothing this process closes can
    /// force that one shut. The grandchild case is therefore **bounded by the deadline, not
    /// eliminated by descriptor hygiene**.
    ///
    /// What must hold: the run ends at the deadline rather than after 30s (or forever), and the
    /// output the child *did* produce survives. That second half is why the readers drain
    /// incrementally — `readDataToEndOfFile()` returns everything only at EOF, so a timed-out
    /// run using it reports nothing at all, discarding the very evidence that explains the hang.
    @Test("a grandchild holding the pipe is bounded by the deadline", .timeLimit(.minutes(1)))
    func grandchildHoldingPipeIsBounded() throws {
        let out = try ProcessRunner.run(
            "/bin/sh",
            arguments: ["-c", "echo hello; sleep 30 & exit 0"],
            timeout: 3
        )

        // Exit 124 is deterministic proof the deadline fired — asserting on measured elapsed
        // time would flake under load, and the suite's `.timeLimit` already fails a real hang.
        #expect(out.exitCode == 124, "expected the deadline to bound the grandchild")
        // And the output the child produced before exiting is not lost.
        #expect(out.stdout.contains("hello"), "partial output was discarded: \(out.stdout.debugDescription)")
    }

    /// A process that simply never finishes must be bounded, whatever the reason. Closing
    /// descriptors does not help here — this is what the deadline is for.
    @Test("a hanging child is terminated at the deadline", .timeLimit(.minutes(1)))
    func hangingChildIsTerminated() throws {
        let out = try ProcessRunner.run("/bin/sh", arguments: ["-c", "sleep 60"], timeout: 2)

        #expect(out.exitCode == 124, "a timed-out run must report the conventional timeout code")
        #expect(out.stderr.lowercased().contains("timed out"),
                "the timeout must be named, not silent: \(out.stderr)")
    }

    /// The guard on the existing behaviour. The concurrent-read fix for the 64 KB buffer
    /// deadlock must not regress — a process writing heavily to both streams still returns
    /// complete output.
    @Test("large output on both streams is still captured in full", .timeLimit(.minutes(1)))
    func largeOutputStillWorks() throws {
        let out = try ProcessRunner.run(
            "/bin/sh",
            arguments: ["-c", "for i in $(seq 1 5000); do echo \"out $i\"; echo \"err $i\" >&2; done"],
            timeout: 60
        )
        #expect(out.exitCode == 0)
        #expect(out.stdout.contains("out 5000"), "stdout truncated")
        #expect(out.stderr.contains("err 5000"), "stderr truncated")
    }

    /// A fast process must not pay for the deadline machinery.
    @Test("a fast process returns promptly and correctly", .timeLimit(.minutes(1)))
    func fastProcessUnaffected() throws {
        let out = try ProcessRunner.run("/bin/echo", arguments: ["quick"], timeout: 30)
        #expect(out.exitCode == 0)
        #expect(out.stdout.contains("quick"))
    }

    /// Merged-stderr callers take the same path and must also be bounded.
    @Test("mergeStderr is bounded too", .timeLimit(.minutes(1)))
    func mergedStderrIsBounded() throws {
        let out = try ProcessRunner.run(
            "/bin/sh", arguments: ["-c", "sleep 60"], mergeStderr: true, timeout: 2)
        #expect(out.exitCode == 124)
    }
}

/// Tests that a timed-out child's descendants die with it.
///
/// The deadline above bounds *our wait*, not *their lifetime*: `Process.terminate()`
/// signals the direct child alone, so a child that spawned helpers dies while they
/// continue. Reproduced in the wild as a `swift-test` orphan alive after 6h55m.
/// The fix spawns every child as the leader of a fresh process group and signals the
/// group at the deadline — see `project/plans/proposals/SubprocessDescendantReaping.md`.
@Suite("ProcessRunner descendant reaping")
struct ProcessRunnerDescendantTests {

    /// **The orphan reproduction.** The child prints its background grandchild's pid and
    /// **exits immediately** — this is the shape that leaks. `Process` spawns the child
    /// as leader of its own process group, so a child still alive at the deadline takes
    /// its group down with `terminate()`; but `terminate()` on an *exited* child is a
    /// no-op, and the grandchild it left behind survived — reproduced as a `swift-test`
    /// orphan alive after 6h55m. The group outlives its leader, so the fix signals the
    /// group by id at the deadline.
    @Test("a grandchild orphaned by an exited child dies at the deadline", .timeLimit(.minutes(1)))
    func orphanedGrandchildDiesAtDeadline() throws {
        let out = try ProcessRunner.run(
            "/bin/sh",
            arguments: ["-c", "sleep 300 & echo $!; exit 0"],
            timeout: 2
        )
        // The grandchild holds the inherited pipe open, so the run still hits the
        // deadline even though the child exited at once — the 46-minute Alamofire shape.
        #expect(out.exitCode == 124, "the deadline itself must still fire")

        let pidText = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let grandchild = Int32(pidText), grandchild > 1 else {
            Issue.record("could not parse the grandchild pid from: \(out.stdout.debugDescription)")
            return
        }
        // Whatever happens below, do not leak the very orphan this test demonstrates.
        defer { _ = kill(grandchild, SIGKILL) }

        // The kill sequence is SIGTERM → grace → SIGKILL, so give it a bounded moment.
        // `kill(pid, 0)` probes liveness: ESRCH means the process is gone.
        var alive = true
        for _ in 0..<50 where alive {
            if kill(grandchild, 0) == -1 && errno == ESRCH {
                alive = false
            } else {
                usleep(100_000)
            }
        }
        #expect(alive == false, "grandchild \(grandchild) outlived the deadline — the orphan leak")
    }

    /// The regression guard for what already worked: a child still *alive* at the
    /// deadline takes its whole group with it, because `Process` made it a group
    /// leader and the runner signals the group.
    @Test("a grandchild of a still-running child dies at the deadline", .timeLimit(.minutes(1)))
    func liveChildGroupDiesAtDeadline() throws {
        let out = try ProcessRunner.run(
            "/bin/sh",
            arguments: ["-c", "sleep 300 & echo $!; wait"],
            timeout: 2
        )
        #expect(out.exitCode == 124, "the deadline itself must still fire")

        let pidText = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let grandchild = Int32(pidText), grandchild > 1 else {
            Issue.record("could not parse the grandchild pid from: \(out.stdout.debugDescription)")
            return
        }
        defer { _ = kill(grandchild, SIGKILL) }

        var alive = true
        for _ in 0..<50 where alive {
            if kill(grandchild, 0) == -1 && errno == ESRCH {
                alive = false
            } else {
                usleep(100_000)
            }
        }
        #expect(alive == false, "grandchild \(grandchild) outlived the deadline")
    }
}

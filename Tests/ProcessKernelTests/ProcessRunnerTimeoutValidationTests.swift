import Foundation
import Testing
import ProcessKernel

/// Tests what `ProcessRunner` does with a timeout that is not an ordinary positive number.
///
/// `timeout` is a caller-supplied `TimeInterval`, and callers compute it: a remaining budget is
/// `deadline.timeIntervalSinceNow`, a scaled one is `base * factor`. Arithmetic like that yields
/// a negative number routinely and a NaN or an infinity occasionally.
///
/// Before this suite the runner had two answers for those, and neither was chosen. A NaN, an
/// infinity or anything past ~292 years reached `DispatchTime + Double`, which saturates all
/// three to `DISPATCH_TIME_FOREVER` — so the runner whose whole purpose is a deadline waited
/// without one. And had that wait ever ended in a timeout, `Int(timeout)` formatting the
/// message would have stopped the process outright.
///
/// Every refusal here is made against an executable that does not exist. `Process.run()` would
/// throw its own error for that path, so seeing ``ProcessRunner/InvalidTimeout`` instead is the
/// proof that the timeout was judged before anything was spawned.
@Suite("ProcessRunner timeout validation")
struct ProcessRunnerTimeoutValidationTests {

    private static let noSuchExecutable = "/nonexistent/process-kernel-test-binary"

    private static func timeoutNote(_ detail: String) -> String {
        "\nprocess-kernel: `/bin/sh` timed out after \(detail) and was terminated."
    }

    @Test("a NaN timeout is refused before anything is spawned")
    func nanIsRefused() {
        #expect(throws: ProcessRunner.InvalidTimeout.notANumber) {
            try ProcessRunner.run(Self.noSuchExecutable, timeout: .nan)
        }
    }

    @Test("an infinite timeout is refused, in either direction",
          arguments: [TimeInterval.infinity, -TimeInterval.infinity])
    func infinityIsRefused(timeout: TimeInterval) {
        #expect(throws: ProcessRunner.InvalidTimeout.infinite) {
            try ProcessRunner.run(Self.noSuchExecutable, timeout: timeout)
        }
    }

    @Test("a finite timeout past the maximum is refused, and the error carries it",
          arguments: [ProcessRunner.maximumTimeout.nextUp, 9_223_372_037, 1e300,
                      TimeInterval.greatestFiniteMagnitude])
    func pastMaximumIsRefused(timeout: TimeInterval) {
        #expect(throws: ProcessRunner.InvalidTimeout.exceedsMaximum(timeout)) {
            try ProcessRunner.run(Self.noSuchExecutable, timeout: timeout)
        }
    }

    @Test("the maximum is one billion seconds, and is itself accepted", .timeLimit(.minutes(1)))
    func maximumIsAccepted() throws {
        #expect(ProcessRunner.maximumTimeout == 1_000_000_000)
        let out = try ProcessRunner.run(
            "/bin/echo", arguments: ["bounded"], timeout: ProcessRunner.maximumTimeout)
        #expect(out.exitCode == 0)
        #expect(out.stdout == "bounded\n")
    }

    /// A negative budget is what `deadline.timeIntervalSinceNow` returns once the deadline has
    /// passed. It is not a malformed request; it is a budget already spent, and it is answered
    /// the way every other spent budget is — exit code 124 — with the figure the caller passed
    /// reported rather than rounded away.
    @Test("a negative timeout is a budget already spent: 124, and the note says so",
          .timeLimit(.minutes(1)))
    func negativeIsAlreadySpent() throws {
        let out = try ProcessRunner.run("/bin/sh", arguments: ["-c", "sleep 60"], timeout: -5)
        #expect(out.exitCode == 124)
        #expect(out.stdout == "")
        #expect(out.stderr == Self.timeoutNote("0s — its budget of -5.0s was already spent —"))
    }

    @Test("a zero timeout is a budget already spent too", .timeLimit(.minutes(1)))
    func zeroIsAlreadySpent() throws {
        let out = try ProcessRunner.run("/bin/sh", arguments: ["-c", "sleep 60"], timeout: 0)
        #expect(out.exitCode == 124)
        #expect(out.stderr == Self.timeoutNote("0s — its budget of 0.0s was already spent —"))
    }

    /// The note used to truncate: a half-second budget was reported as "timed out after 0s".
    @Test("a fractional timeout is reported as given, not truncated", .timeLimit(.minutes(1)))
    func fractionalIsReportedExactly() throws {
        let out = try ProcessRunner.run("/bin/sh", arguments: ["-c", "sleep 60"], timeout: 0.5)
        #expect(out.exitCode == 124)
        #expect(out.stderr == Self.timeoutNote("0.5s"))
    }

    /// The guard on the existing wording: a whole number of seconds reads as it always has.
    @Test("a whole-second timeout keeps its wording", .timeLimit(.minutes(1)))
    func wholeSecondsUnchanged() throws {
        let out = try ProcessRunner.run("/bin/sh", arguments: ["-c", "sleep 60"], timeout: 2)
        #expect(out.exitCode == 124)
        #expect(out.stderr == Self.timeoutNote("2s"))
    }

    @Test("each refusal says what was wrong and what is accepted")
    func descriptions() {
        #expect(ProcessRunner.InvalidTimeout.notANumber.description
            == "process-kernel: the timeout is not a number. Nothing was run.")
        #expect(ProcessRunner.InvalidTimeout.infinite.description
            == "process-kernel: the timeout is infinite, and a run with no deadline is the one thing this runner does not offer. Nothing was run.")
        #expect(ProcessRunner.InvalidTimeout.exceedsMaximum(2e9).description
            == "process-kernel: the timeout of 2000000000.0s is past the maximum of 1000000000.0s. Nothing was run.")
    }
}

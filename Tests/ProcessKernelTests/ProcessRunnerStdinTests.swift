import Foundation
import Testing
import ProcessKernel

/// Writing to a child's stdin is the same hazard as reading its stdout, reflected.
///
/// The session that produced these tests spent itself on reads that never returned. The write
/// direction is identical and had gone unexamined: a payload larger than the ~64 KB pipe buffer
/// blocks the writer until the child drains it, and a child that reads its input to EOF before
/// producing anything — the normal shape for a filter — will not drain until the writer finishes.
/// Both sides then wait forever.
///
/// `PluginRunner` writes inline (`stdinPipe.fileHandleForWriting.write(stdin)`), so it carries
/// this bug today. That is why `stdin:` belongs in the audited runner rather than being plumbed
/// through: adding it naively would move the hazard into the one file whose entire justification
/// is that it is the place where such things are handled correctly.
@Suite("ProcessRunner stdin")
struct ProcessRunnerStdinTests {

    /// **The test that forces the design.**
    ///
    /// 256 KB is comfortably past the pipe buffer, and `cat` does not echo until it reaches EOF.
    /// Any implementation that writes stdin inline on the calling thread deadlocks here and the
    /// `.timeLimit` fails the run. Passing requires the write to proceed concurrently with the
    /// reads — which is precisely the shape the readers already have.
    @Test("a payload larger than the pipe buffer does not deadlock", .timeLimit(.minutes(1)))
    func oversizedStdinDoesNotDeadlock() throws {
        let payload = String(repeating: "x", count: 256 * 1024)
        let out = try ProcessRunner.run(
            "/bin/cat",
            stdin: Data(payload.utf8),
            timeout: 30)

        #expect(out.exitCode == 0)
        #expect(out.stdout.count == payload.count,
                "the child received \(out.stdout.count) of \(payload.count) bytes")
    }

    /// The ordinary case: a small payload arrives intact.
    @Test("a small payload reaches the child", .timeLimit(.minutes(1)))
    func smallStdinIsDelivered() throws {
        let out = try ProcessRunner.run("/bin/cat", stdin: Data("hello".utf8), timeout: 10)
        #expect(out.exitCode == 0)
        #expect(out.stdout.contains("hello"))
    }

    /// The child must see EOF, or it waits for input that will never come. Closing the write end
    /// after the payload is what ends `cat`; without it this hangs and the deadline fires.
    @Test("the child sees end-of-input", .timeLimit(.minutes(1)))
    func stdinIsClosedAfterWriting() throws {
        let out = try ProcessRunner.run(
            "/bin/sh",
            arguments: ["-c", "while read line; do echo \"got $line\"; done"],
            stdin: Data("a\nb\nc\n".utf8),
            timeout: 15)

        #expect(out.exitCode == 0, "the loop must end at EOF rather than at the deadline")
        #expect(out.stdout.contains("got c"))
    }

    /// A child that exits without reading its input must not hang the writer. The write fails
    /// with EPIPE, which is the correct outcome and must be swallowed rather than thrown — the
    /// run succeeded, the child simply did not want the input.
    @Test("a child that ignores stdin does not hang the writer", .timeLimit(.minutes(1)))
    func childIgnoringStdinIsFine() throws {
        let out = try ProcessRunner.run(
            "/bin/sh",
            arguments: ["-c", "echo done"],
            stdin: Data(String(repeating: "y", count: 256 * 1024).utf8),
            timeout: 15)

        #expect(out.exitCode == 0)
        #expect(out.stdout.contains("done"))
    }

    /// No stdin means no stdin pipe at all — existing callers must be untouched.
    @Test("omitting stdin leaves behaviour unchanged", .timeLimit(.minutes(1)))
    func noStdinIsUnchanged() throws {
        let out = try ProcessRunner.run("/bin/echo", arguments: ["unchanged"], timeout: 10)
        #expect(out.exitCode == 0)
        #expect(out.stdout.contains("unchanged"))
    }

    /// The deadline still governs when a payload is in flight.
    @Test("a hanging child with stdin is still bounded", .timeLimit(.minutes(1)))
    func stdinRunIsStillBounded() throws {
        let out = try ProcessRunner.run(
            "/bin/sh",
            arguments: ["-c", "sleep 60"],
            stdin: Data("ignored".utf8),
            timeout: 2)
        #expect(out.exitCode == 124)
    }
}

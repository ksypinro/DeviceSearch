import Foundation
import Testing
import SearchCore
import SearchIndex
@testable import DeviceSearch
import SearchTestSupport

@Suite("Deadline")
struct DeadlineTests {
    @Test func returnsFastResults() async throws {
        let value = try await withDeadline(.seconds(1)) { 42 }
        #expect(value == 42)
    }

    @Test func throwsWhenLate() async {
        await #expect(throws: DeadlineExceeded.self) {
            try await withDeadline(.milliseconds(20)) {
                try await Task.sleep(for: .seconds(5))
                return 1
            }
        }
    }

    /// A model call that keeps running after cancellation must not hold the fallback past the deadline.
    @Test func throwsAtTheDeadlineWhenTheOperationIgnoresCancellation() async {
        let start = ContinuousClock.now
        await #expect(throws: DeadlineExceeded.self) {
            try await withDeadline(.milliseconds(50)) {
                await Task.detached { try? await Task.sleep(for: .seconds(3)) }.value
                return 1
            }
        }
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @Test func cancellingTheCallerStopsWaiting() async {
        let start = ContinuousClock.now
        let task = Task {
            try await withDeadline(.seconds(5)) {
                await Task.detached { try? await Task.sleep(for: .seconds(3)) }.value
                return 1
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - start < .seconds(1))
    }
}

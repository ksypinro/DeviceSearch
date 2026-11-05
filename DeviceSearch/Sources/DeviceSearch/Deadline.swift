import Synchronization

/// Thrown when an operation misses its deadline.
public struct DeadlineExceeded: Error, Equatable {
    public init() {}
}

/// Runs `operation`, throwing `DeadlineExceeded` if it does not finish within `duration`.
///
/// Returns as soon as the deadline passes, even when `operation` ignores cancellation. A Foundation Models
/// call that has not produced its first token keeps running for seconds after it is cancelled, and a task
/// group would wait for it, so the race runs in unstructured tasks and the loser is cancelled, not awaited.
/// Cancelling the caller cancels both and throws `CancellationError`.
public func withDeadline<T: Sendable>(_ duration: Duration,
                                      _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let race = DeadlineRace<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            race.start(continuation)
            race.add(Task {
                do { race.finish(.success(try await operation())) } catch { race.finish(.failure(error)) }
            })
            race.add(Task {
                // A cancelled sleep means the race already ended; the result is ignored then.
                try? await Task.sleep(for: duration)
                race.finish(.failure(DeadlineExceeded()))
            })
        }
    } onCancel: {
        race.finish(.failure(CancellationError()))
    }
}

/// The first result wins; it resumes the caller once and cancels both tasks.
private final class DeadlineRace<T: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<T, any Error>?
        var result: Result<T, any Error>?
        var tasks: [Task<Void, Never>] = []
    }

    private let state = Mutex(State())

    /// The caller may already be cancelled, so a result can arrive before the continuation does.
    func start(_ continuation: CheckedContinuation<T, any Error>) {
        let early = state.withLock { state -> Result<T, any Error>? in
            if state.result == nil { state.continuation = continuation }
            return state.result
        }
        if let early { continuation.resume(with: early) }
    }

    func add(_ task: Task<Void, Never>) {
        let finished = state.withLock { state -> Bool in
            if state.result == nil { state.tasks.append(task) }
            return state.result != nil
        }
        if finished { task.cancel() }
    }

    func finish(_ result: Result<T, any Error>) {
        let won = state.withLock { state -> (CheckedContinuation<T, any Error>?, [Task<Void, Never>])? in
            guard state.result == nil else { return nil }
            state.result = result
            defer { state.continuation = nil; state.tasks = [] }
            return (state.continuation, state.tasks)
        }
        guard let (continuation, tasks) = won else { return }
        // Cancel before resuming, so a late streaming callback sees `Task.isCancelled`.
        for task in tasks { task.cancel() }
        continuation?.resume(with: result)
    }
}

import Synchronization
import SearchCore
import DeviceSearch

/// Projects the app's live device cache into search events (design doc §11 X01).
///
/// Call `publish` with every state the UI shows — optimistic updates and saga compensations included — and pass
/// `events` to `SearchEngineRegistry.open`. The diff turns status-only changes into the fast path and everything
/// else into a coalesced rebuild.
final class DeviceEventBridge: Sendable {
    let events: AsyncStream<DeviceEvent>
    private let continuation: AsyncStream<DeviceEvent>.Continuation
    private let last: Mutex<[DeviceRecord]>

    init(initial: [DeviceRecord]) {
        (events, continuation) = AsyncStream.makeStream(of: DeviceEvent.self, bufferingPolicy: .unbounded)
        last = Mutex(initial)
    }

    func publish(_ devices: [DeviceRecord]) {
        let previous = last.withLock { current -> [DeviceRecord] in
            defer { current = devices }
            return current
        }
        for event in DeviceEventDiffer.diff(old: previous, new: devices) { continuation.yield(event) }
    }

    func finish() { continuation.finish() }
}

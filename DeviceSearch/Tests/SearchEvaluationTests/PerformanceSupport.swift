import Foundation

/// Budgets from design doc §12 (B01, B02). Debug builds are about 10× slower than release, so the bounds
/// stretch in debug; run `swift test -c release --filter Performance` for the real numbers.
enum Budget {
    #if DEBUG
    static let factor = 10.0
    #else
    static let factor = 1.0
    #endif

    static func ms(_ value: Double) -> Duration { .microseconds(Int(value * factor * 1000)) }
}

func measure(_ runs: Int, _ body: () -> Void) -> [Duration] {
    let clock = ContinuousClock()
    return (0..<runs).map { _ in clock.measure(body) }
}

func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
}

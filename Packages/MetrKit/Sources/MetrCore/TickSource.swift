import Foundation

/// One repeating `DispatchSourceTimer` on a caller-supplied queue.
///
/// The tick closure is created and run inside the package (nonisolated), so it is
/// never inferred as MainActor-isolated (RESEARCH Pitfall 1). All mutable state is
/// confined to `queue`.
public final class TickSource: @unchecked Sendable {
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private var last: UInt64 = 0

    public init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// Starts (or restarts) the timer.
    /// - Parameters:
    ///   - interval: repeat interval in seconds.
    ///   - firstFireAfter: delay before the first fire; `nil` means one interval.
    ///   - leewayFraction: timer leeway as a fraction of the interval.
    ///   - onTick: receives the measured seconds since the previous fire (or since start).
    public func start(
        interval: Double,
        firstFireAfter: Double? = nil,
        leewayFraction: Double = 0.2,
        onTick: @escaping @Sendable (_ elapsed: Double) -> Void
    ) {
        queue.async {
            self.timer?.cancel()
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            self.last = DispatchTime.now().uptimeNanoseconds
            let first = firstFireAfter ?? interval
            t.schedule(
                deadline: .now() + first,
                repeating: interval,
                leeway: .nanoseconds(Int(interval * leewayFraction * 1e9))
            )
            t.setEventHandler { [weak self] in
                guard let self else { return }
                let now = DispatchTime.now().uptimeNanoseconds
                let dt = Double(now &- self.last) / 1e9
                self.last = now
                onTick(dt)
            }
            t.resume()
            self.timer = t
        }
    }

    public func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
        }
    }
}

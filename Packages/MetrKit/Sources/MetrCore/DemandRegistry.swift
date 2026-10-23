/// The set of consumers that currently want faster sampling.
public struct DemandRegistry: Sendable, Equatable {
    public private(set) var active: Set<DemandConsumer> = []

    public init() {}

    /// Returns true only when the set changed.
    @discardableResult
    public mutating func register(_ consumer: DemandConsumer) -> Bool {
        active.insert(consumer).inserted
    }

    /// Returns true only when the set changed. Cancelling an absent consumer is a no-op.
    @discardableResult
    public mutating func cancel(_ consumer: DemandConsumer) -> Bool {
        active.remove(consumer) != nil
    }
}

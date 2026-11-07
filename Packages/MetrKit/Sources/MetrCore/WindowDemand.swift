/// The sections of the full window's sidebar. The case order is the sidebar order (D-04) and the
/// raw values are the persisted `windowSection` values (D-03): the last-visited section is stored
/// by raw value, so renaming a case would orphan a user's stored choice.
public enum WindowSection: String, Sendable, CaseIterable {
    case cpu, memory, disk, network, gpu, processes
}

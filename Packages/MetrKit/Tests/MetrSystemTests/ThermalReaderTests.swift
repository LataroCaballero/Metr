import Foundation
import MetrCore
import Testing

@testable import MetrSystem

@Suite struct ThermalReaderTests {
    @Test func currentMatchesProcessInfo() {
        let expected = ThermalLevel(thermalStateRawValue: ProcessInfo.processInfo.thermalState.rawValue)
        #expect(ThermalReader.current() == expected)
    }

    @Test func notificationIsTheSystemOne() {
        #expect(ThermalReader.didChangeNotification == ProcessInfo.thermalStateDidChangeNotification)
    }
}

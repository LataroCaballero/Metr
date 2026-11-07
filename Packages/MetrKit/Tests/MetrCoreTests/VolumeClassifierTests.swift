import Testing

@testable import MetrCore

@Suite struct VolumeClassifierTests {
    private let startup = VolumeFacts(
        path: "/", name: "Macintosh HD", wholeDisk: "disk3", isInternal: true, isRoot: true,
        deviceProtocol: "Apple Fabric", totalBytes: 245_107_195_904,
        importantAvailableBytes: 11_504_558_144, availableBytes: 11_462_385_664)

    private func external(
        _ name: String, disk: String, path: String? = nil, total: Int64? = 1_000_000_000,
        important: Int64? = 400_000_000, available: Int64? = 400_000_000
    ) -> VolumeFacts {
        VolumeFacts(
            path: path ?? "/Volumes/\(name)", name: name, wholeDisk: disk, deviceProtocol: "USB",
            totalBytes: total, importantAvailableBytes: important, availableBytes: available)
    }

    @Test func thisMacsVolumes() {
        let lexar = VolumeFacts(
            path: "/Volumes/Lexar", name: "Lexar", wholeDisk: "disk4", deviceProtocol: "USB",
            totalBytes: 1_023_966_052_352, importantAvailableBytes: 0, availableBytes: 899_851_485_184)
        let image = VolumeFacts(
            path: "/Volumes/XcodeDev", name: "XcodeDev", wholeDisk: "disk6",
            deviceProtocol: "Virtual Interface", totalBytes: 200_000_000_000,
            importantAvailableBytes: 100_000_000_000, availableBytes: 100_000_000_000)

        let rows = VolumeClassifier.volumes(from: [lexar, image, startup])

        #expect(rows.count == 2)
        #expect(rows.first?.name == "Macintosh HD")
        #expect(rows.first?.role == .startup)
        #expect(rows.first?.freeBytes == 11_504_558_144)
        #expect(rows.first?.totalBytes == 245_107_195_904)
        #expect(rows.last?.name == "Lexar")
        #expect(rows.last?.role == .external)
        #expect(rows.last?.freeBytes == 899_851_485_184)
    }

    @Test func oneRowPerContainer() {
        let data = VolumeFacts(
            path: "/System/Volumes/Data", name: "Data", wholeDisk: "disk3", isInternal: true,
            deviceProtocol: "Apple Fabric", totalBytes: 245_107_195_904,
            importantAvailableBytes: 11_504_558_144, availableBytes: 11_462_385_664)
        let withRoot = VolumeClassifier.volumes(from: [data, startup])
        #expect(withRoot.count == 1)
        #expect(withRoot.first?.name == "Macintosh HD")
        #expect(withRoot.first?.id == "disk3")

        let second = external("Zeta", disk: "disk7")
        let first = external("Alpha", disk: "disk7")
        let noRoot = VolumeClassifier.volumes(from: [second, first])
        #expect(noRoot.count == 1)
        #expect(noRoot.first?.name == "Alpha")
        #expect(noRoot.first?.id == "disk7")
    }

    @Test func skipRules() {
        var network = external("Share", disk: "disk9")
        network.isLocal = false
        var hidden = external("Hidden", disk: "disk10")
        hidden.isBrowsable = false
        var backup = external("Backups", disk: "disk11")
        backup.isTimeMachine = true
        var image = external("Image", disk: "disk12")
        image.deviceProtocol = "Virtual Interface"

        #expect(VolumeClassifier.volumes(from: [network, hidden, backup, image]).isEmpty)
        #expect(VolumeClassifier.volumes(from: [network, startup, hidden, backup, image]).map(\.name) == ["Macintosh HD"])
    }

    @Test func ordering() {
        var internalB = external("Disk 10", disk: "disk15")
        internalB.isInternal = true
        var internalA = external("Disk 2", disk: "disk16")
        internalA.isInternal = true
        let backupLate = external("Backup", disk: "disk8")
        let backupEarly = external("Backup", disk: "disk5")
        let camera = external("Camera", disk: "disk14")

        let all = [camera, backupLate, internalB, backupEarly, internalA, startup]
        let expected = ["Macintosh HD", "Disk 2", "Disk 10", "Backup", "Backup", "Camera"]
        #expect(VolumeClassifier.volumes(from: all).map(\.name) == expected)
        #expect(VolumeClassifier.volumes(from: all.reversed()).map(\.name) == expected)

        let backups = VolumeClassifier.volumes(from: all).filter { $0.name == "Backup" }
        #expect(backups.map(\.id) == ["disk5", "disk8"])
        #expect(VolumeClassifier.volumes(from: all.reversed()).filter { $0.name == "Backup" }.map(\.id) == ["disk5", "disk8"])
        #expect(VolumeClassifier.volumes(from: all).map(\.role) == [.startup, .internal, .internal, .external, .external, .external])
    }

    @Test func equalNamesOnDifferentDisksStaySeparate() {
        let rows = VolumeClassifier.volumes(from: [
            external("Backup", disk: "disk8"), external("Backup", disk: "disk5"),
        ])
        #expect(rows.count == 2)
        #expect(rows.map(\.id) == ["disk5", "disk8"])
    }

    @Test func aMacWithOnlyTheStartupVolumeGivesOneRow() {
        #expect(VolumeClassifier.volumes(from: [startup]).count == 1)
        #expect(VolumeClassifier.volumes(from: []).isEmpty)
    }

    @Test func capacityRules() throws {
        let unknown = VolumeClassifier.volumes(from: [external("A", disk: "disk20", total: nil)])
        #expect(unknown.first?.freeBytes == nil)
        #expect(unknown.first?.usedBytes == nil)
        #expect(unknown.first?.usedFraction == nil)

        let zero = VolumeClassifier.volumes(from: [external("B", disk: "disk21", total: 0)])
        #expect(zero.first?.freeBytes == nil)
        #expect(zero.first?.usedBytes == nil)

        #expect(VolumeClassifier.free(important: 0, available: 900) == 900)
        #expect(VolumeClassifier.free(important: 900, available: 800) == 900)
        #expect(VolumeClassifier.free(important: nil, available: 800) == 800)
        #expect(VolumeClassifier.free(important: 700, available: nil) == 700)
        #expect(VolumeClassifier.free(important: nil, available: nil) == nil)

        let row = try #require(VolumeClassifier.volumes(from: [external("C", disk: "disk22")]).first)
        #expect(row.totalBytes == 1_000_000_000)
        #expect(row.freeBytes == 400_000_000)
        #expect(row.usedBytes == 600_000_000)
        #expect(row.usedFraction == 0.6)

        // Free larger than the total never gives a negative figure.
        let over = try #require(
            VolumeClassifier.volumes(from: [external("D", disk: "disk23", total: 100, important: 500, available: 500)]).first)
        #expect(over.usedBytes == 0)
        #expect(over.usedFraction == 0)
    }

    @Test func nonAPFSExternalNeverShowsAFalseZero() throws {
        let exfat = external("Lexar", disk: "disk4", total: 1_000, important: 0, available: 900)
        let row = try #require(VolumeClassifier.volumes(from: [exfat]).first)
        #expect(row.freeBytes == 900)
        #expect(row.usedBytes == 100)
    }

    @Test func namesAreSanitized() {
        let hostile = external("Dri\u{202E}ve\nX", disk: "disk30")
        let empty = external("", disk: "disk31")
        let rows = VolumeClassifier.volumes(from: [hostile, empty])
        #expect(rows.contains { $0.name == "DriveX" })
        #expect(rows.contains { $0.name == "—" })
        #expect(!rows.contains { $0.name.contains("\u{202E}") || $0.name.contains("\n") })
    }

    @Test func fallsBackToThePathWhenThereIsNoWholeDisk() {
        var odd = external("Odd", disk: "x")
        odd.wholeDisk = nil
        let rows = VolumeClassifier.volumes(from: [odd])
        #expect(rows.first?.id == "/Volumes/Odd")
    }
}

/// How fast the Mac reads and writes its storage, summed over every physical block-storage driver
/// (WIN-02, D-08). Disk images are not counted: their I/O is already on the drive that backs them.
public struct DiskIOReading: Sendable, Equatable {
    /// Bytes per second read and written over the last sampling interval, decimal.
    public var readBytesPerSec: Double
    public var writeBytesPerSec: Double

    public init(readBytesPerSec: Double, writeBytesPerSec: Double) {
        self.readBytesPerSec = readBytesPerSec
        self.writeBytesPerSec = writeBytesPerSec
    }
}

import Foundation

/// Measures allocated disk space with `getattrlistbulk`, which returns a whole directory's
/// entries and sizes in one system call instead of one `stat` per file.
///
/// This is the only file in devdisk that reads raw memory. The kernel fills a byte buffer
/// with variable-length records; every read below is bounds-checked against the record and
/// the buffer before it happens, and nothing outside this file sees a pointer.
enum Walker {
    struct Measurement: Equatable {
        /// Allocated bytes under the root, hard links counted once, other volumes excluded.
        var total: Int64 = 0
        /// Subtree totals for the watched directories found under the root.
        var watched: [String: Int64] = [:]
    }

    /// Sizes `root` and, in the same pass, any `watch` directories nested inside it.
    static func measure(_ root: String, watch: Set<String> = []) -> Measurement {
        var info = stat()
        guard lstat(root, &info) == 0 else { return Measurement() }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            return Measurement(total: Int64(info.st_blocks) * 512)
        }
        let fd = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { return Measurement() }
        let pass = Pass(device: info.st_dev, watch: watch)
        defer { pass.buffer.deallocate() }
        let total = pass.walk(fd: fd, path: watch.isEmpty ? nil : root)
        return Measurement(total: total, watched: pass.watched)
    }

    // Attribute bits from <sys/attr.h>, spelled out because Swift imports some as signed.
    private static let commonReturned: UInt32 = 0x8000_0000
    private static let commonName: UInt32 = 0x0000_0001
    private static let commonDevice: UInt32 = 0x0000_0002
    private static let commonType: UInt32 = 0x0000_0008
    private static let commonFileID: UInt32 = 0x0200_0000
    private static let fileLinkCount: UInt32 = 0x0000_0001
    private static let fileAllocSize: UInt32 = 0x0000_0004
    private static let typeDirectory: UInt32 = 2

    private final class Pass {
        let device: dev_t
        let watch: Set<String>
        var watched: [String: Int64] = [:]
        var seenLinks: Set<UInt64> = []
        let capacity = 256 * 1024
        let buffer: UnsafeMutableRawPointer

        init(device: dev_t, watch: Set<String>) {
            self.device = device
            self.watch = watch
            buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 8)
        }

        /// Returns the subtree total and closes `fd`. `path` is tracked only when something is watched.
        func walk(fd: Int32, path: String?) -> Int64 {
            var total: Int64 = 0
            var subdirectories: [String] = []
            var request = attrlist()
            request.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
            request.commonattr = Walker.commonReturned | Walker.commonName | Walker.commonDevice
                | Walker.commonType | Walker.commonFileID
            request.fileattr = Walker.fileLinkCount | Walker.fileAllocSize

            // The buffer is fully consumed before recursing, so one buffer serves the whole pass.
            while true {
                let count = getattrlistbulk(fd, &request, buffer, capacity, 0)
                guard count > 0 else { break }
                var offset = 0
                for _ in 0..<count {
                    guard offset + 4 <= capacity else { break }
                    let length = Int(buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                    guard length >= 24, offset + length <= capacity else { break }
                    let end = offset + length
                    var field = offset + 4

                    // attribute_set_t: which of the requested attributes this record carries.
                    let common = buffer.loadUnaligned(fromByteOffset: field, as: UInt32.self)
                    let file = buffer.loadUnaligned(fromByteOffset: field + 12, as: UInt32.self)
                    field += 20

                    var name = ""
                    var entryDevice = device
                    var type: UInt32 = 0
                    var fileID: UInt64 = 0
                    if common & Walker.commonName != 0, field + 8 <= end {
                        let dataOffset = Int(buffer.loadUnaligned(fromByteOffset: field, as: Int32.self))
                        let dataLength = Int(buffer.loadUnaligned(fromByteOffset: field + 4, as: UInt32.self))
                        let start = field + dataOffset
                        if dataLength > 0, start >= offset, start + dataLength <= end {
                            // The length includes the trailing NUL.
                            let bytes = UnsafeRawBufferPointer(start: buffer + start, count: dataLength - 1)
                            name = String(decoding: bytes, as: UTF8.self)
                        }
                        field += 8
                    }
                    if common & Walker.commonDevice != 0, field + 4 <= end {
                        entryDevice = buffer.loadUnaligned(fromByteOffset: field, as: dev_t.self)
                        field += 4
                    }
                    if common & Walker.commonType != 0, field + 4 <= end {
                        type = buffer.loadUnaligned(fromByteOffset: field, as: UInt32.self)
                        field += 4
                    }
                    if common & Walker.commonFileID != 0, field + 8 <= end {
                        fileID = buffer.loadUnaligned(fromByteOffset: field, as: UInt64.self)
                        field += 8
                    }

                    if type == Walker.typeDirectory {
                        // Like `du -x`: do not descend into other mounted volumes.
                        if entryDevice == device, !name.isEmpty { subdirectories.append(name) }
                    } else {
                        var links: UInt32 = 1
                        var allocated: Int64 = 0
                        if file & Walker.fileLinkCount != 0, field + 4 <= end {
                            links = buffer.loadUnaligned(fromByteOffset: field, as: UInt32.self)
                            field += 4
                        }
                        if file & Walker.fileAllocSize != 0, field + 8 <= end {
                            allocated = buffer.loadUnaligned(fromByteOffset: field, as: Int64.self)
                        }
                        if links > 1, !seenLinks.insert(fileID).inserted { allocated = 0 }
                        total += allocated
                    }
                    offset = end
                }
            }

            for name in subdirectories {
                let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard child >= 0 else { continue }
                let childPath = path.map { $0 + "/" + name }
                let size = walk(fd: child, path: childPath)
                if let childPath, watch.contains(childPath) { watched[childPath] = size }
                total += size
            }
            close(fd)
            return total
        }
    }
}

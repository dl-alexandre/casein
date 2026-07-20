import Darwin
import Foundation

enum SecurePersistence {
    static func withLock<T>(for url: URL, _ body: () throws -> T) throws -> T {
        let directory = url.deletingLastPathComponent()
        var metadata = stat()
        if lstat(directory.path, &metadata) != 0 {
            guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try FileManager.default.createDirectory(
                at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard mkdir(directory.path, 0o700) == 0 || errno == EEXIST else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard lstat(directory.path, &metadata) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        guard metadata.st_uid == geteuid(),
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_mode & 0o022 == 0
        else { throw CocoaError(.fileWriteNoPermission) }

        let descriptor = open(url.path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    static func readSecurely(at url: URL) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_uid == geteuid(),
              metadata.st_mode & S_IFMT == S_IFREG,
              fchmod(descriptor, 0o600) == 0
        else { throw CocoaError(.fileReadNoPermission) }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    static func replace(_ data: Data, at url: URL) throws {
        let temporary = url.deletingLastPathComponent()
            .appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        var shouldRemove = true
        defer {
            close(descriptor)
            if shouldRemove { unlink(temporary.path) }
        }

        try data.withUnsafeBytes { rawBuffer in
            guard var address = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, address, remaining)
                guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                remaining -= count
                address = address.advanced(by: count)
            }
        }
        guard fsync(descriptor) == 0, Darwin.rename(temporary.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let directory = open(url.deletingLastPathComponent().path, O_RDONLY)
        guard directory >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(directory) }
        guard fsync(directory) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        shouldRemove = false
    }

    static func removeSecurely(at url: URL) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              metadata.st_uid == geteuid(),
              metadata.st_mode & S_IFMT == S_IFREG
        else { throw CocoaError(.fileWriteNoPermission) }
        guard unlink(url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let directory = open(url.deletingLastPathComponent().path, O_RDONLY)
        guard directory >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(directory) }
        guard fsync(directory) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

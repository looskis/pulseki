import Darwin
import Foundation

final class FilesystemCollector: Collector {
    let name = "filesystem"

    private let mountExclude: Matcher
    private let fsTypeExclude: Matcher

    init(config: Config) throws {
        mountExclude = try Matcher(config.filesystemMountPointsExclude)
        fsTypeExclude = try Matcher(config.filesystemFSTypesExclude)
    }

    func collect() throws -> [MetricFamily] {
        var mounts: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&mounts, MNT_NOWAIT)
        guard count > 0, let mounts else { throw CollectorError("getmntinfo failed: \(errnoString())") }

        var size = MetricFamily(name: "node_filesystem_size_bytes", help: "Filesystem size in bytes.", type: .gauge)
        var free = MetricFamily(name: "node_filesystem_free_bytes", help: "Filesystem free space in bytes.", type: .gauge)
        var avail = MetricFamily(name: "node_filesystem_avail_bytes", help: "Filesystem space available to unprivileged users in bytes.", type: .gauge)
        var files = MetricFamily(name: "node_filesystem_files", help: "Filesystem total file nodes.", type: .gauge)
        var filesFree = MetricFamily(name: "node_filesystem_files_free", help: "Filesystem free file nodes.", type: .gauge)
        var readonly = MetricFamily(name: "node_filesystem_readonly", help: "Filesystem read-only status.", type: .gauge)

        for i in 0..<Int(count) {
            let fs = mounts[i]
            let mountpoint = cString(fs.f_mntonname)
            let fstype = cString(fs.f_fstypename)
            if mountExclude.matches(mountpoint) || fsTypeExclude.matches(fstype) { continue }
            let device = cString(fs.f_mntfromname)
            let labels = [("device", device), ("fstype", fstype), ("mountpoint", mountpoint)]
            let blockSize = Double(fs.f_bsize)
            size.add(Double(fs.f_blocks) * blockSize, labels)
            free.add(Double(fs.f_bfree) * blockSize, labels)
            avail.add(Double(fs.f_bavail) * blockSize, labels)
            files.add(Double(fs.f_files), labels)
            filesFree.add(Double(fs.f_ffree), labels)
            readonly.add(fs.f_flags & UInt32(MNT_RDONLY) != 0 ? 1 : 0, labels)
        }
        return [size, free, avail, files, filesFree, readonly]
    }
}

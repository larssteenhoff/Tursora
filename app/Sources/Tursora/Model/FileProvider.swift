import Foundation

/// The one seam that must exist from day one: everything the UI knows about a
/// filesystem goes through here. v1 ships only `LocalFileProvider`; a remote
/// backend later slots in without touching the view layer.
protocol FileProvider: AnyObject {
    /// Blocking; callers are expected to run this off the main thread.
    func listDirectory(_ url: URL) throws -> [FileItem]
    var homeURL: URL { get }
    func displayName(for url: URL) -> String
}

final class LocalFileProvider: FileProvider {
    private let fm = FileManager.default

    /// Folders whose listing also shows another folder's items, as Finder's
    /// does: Apple's own apps live on the read-only system volume, in
    /// /System/Applications, yet appear in Applications and its Utilities.
    /// Keyed by the standardized path of the folder being listed.
    static let finderMergedFolders: [String: URL] = [
        "/Applications": URL(fileURLWithPath: "/System/Applications", isDirectory: true),
        "/Applications/Utilities": URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
    ]
    private let mergedFolders: [String: URL]

    init(mergedFolders: [String: URL] = LocalFileProvider.finderMergedFolders) {
        self.mergedFolders = mergedFolders
    }

    func listDirectory(_ url: URL) throws -> [FileItem] {
        // Foundation refuses to enumerate a symlink used as the directory
        // root (ENOTDIR). Resolve for reading, but retain the requested URL
        // spelling for item/history identity and later symlink-retarget checks.
        let directory = url.resolvingSymlinksInPath()
        var items = try fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: FileItem.resourceKeys,
            options: []
        ).compactMap { child in
            let itemURL = directory.path == url.path ? child : url.appendingPathComponent(child.lastPathComponent)
            return FileItem(url: itemURL)
        }
        // The merged folder's items keep their real location, so opening,
        // Get Info and Reveal act on the actual app; an item of the same name
        // in the listed folder wins.
        if let extra = mergedFolders[url.standardizedFileURL.path],
           let more = try? fm.contentsOfDirectory(at: extra, includingPropertiesForKeys: FileItem.resourceKeys, options: []) {
            let names = Set(items.map(\.name))
            items += more.filter { !names.contains($0.lastPathComponent) }.compactMap { FileItem(url: $0) }
        }
        return items
    }

    var homeURL: URL { fm.homeDirectoryForCurrentUser }

    /// Uses Finder's localized names ("Desktop" stays "Desktop" in a localized
    /// system, volumes show their volume name, etc.).
    func displayName(for url: URL) -> String {
        if url.path == "/" {
            if let name = try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName { return name }
        }
        return fm.displayName(atPath: url.path)
    }
}

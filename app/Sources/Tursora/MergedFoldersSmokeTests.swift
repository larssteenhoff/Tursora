import Foundation

/// Applications and Utilities also list Apple's apps from the system volume,
/// as Finder's do.
enum MergedFoldersSmokeTests: SmokeSuite {
    static var checkPrefix: String { "merged folders: " }

    static func run() {
        print("== applications merged with the system volume ==")
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("tursora-merged-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: root) }
        let user = root.appendingPathComponent("Applications"), system = root.appendingPathComponent("System")
        for folder in [user.appendingPathComponent("Mine.app"), user.appendingPathComponent("Shared.app"),
                       system.appendingPathComponent("Apple.app"), system.appendingPathComponent("Shared.app")] {
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let provider = LocalFileProvider(mergedFolders: [user.standardizedFileURL.path: system])
        let items = (try? provider.listDirectory(user)) ?? []
        let byName = Dictionary(items.map { ($0.name, $0.url.standardizedFileURL) }, uniquingKeysWith: { first, _ in first })
        check("the listing holds the folder's own items and the merged folder's",
              Set(items.map(\.name)) == ["Mine.app", "Shared.app", "Apple.app"] && items.count == 3, "\(items.map(\.name))")
        check("a merged item keeps its real location, so opening it acts on the actual app",
              byName["Apple.app"] == system.appendingPathComponent("Apple.app").standardizedFileURL)
        check("an item in both places is the listed folder's own",
              byName["Shared.app"] == user.appendingPathComponent("Shared.app").standardizedFileURL)
        check("other folders are listed as they are",
              ((try? provider.listDirectory(system)) ?? []).count == 2)
        check("Applications and its Utilities merge in the system volume's folders, as in Finder",
              LocalFileProvider.finderMergedFolders["/Applications"]?.path == "/System/Applications"
              && LocalFileProvider.finderMergedFolders["/Applications/Utilities"]?.path == "/System/Applications/Utilities")
    }
}

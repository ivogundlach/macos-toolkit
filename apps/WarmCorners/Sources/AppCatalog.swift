import AppKit

/// The list of apps offered in the corner pickers. Built once, on first use.
@MainActor
enum AppCatalog {
    struct Entry: Identifiable, Hashable {
        let name: String
        let path: String
        var id: String { path }
    }

    private static var cached: [Entry]?

    static var apps: [Entry] {
        if let cached { return cached }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let roots = [
            "/Applications",
            "/Applications/Utilities",
            "/System/Applications",
            "/System/Applications/Utilities",
            "\(home)/Applications",
        ]
        var seen = Set<String>()
        var entries: [Entry] = []
        for root in roots {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
            for item in contents where item.hasSuffix(".app") {
                let name = String(item.dropLast(4))
                guard seen.insert(name).inserted else { continue }
                entries.append(Entry(name: name, path: "\(root)/\(item)"))
            }
        }
        entries.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        cached = entries
        return entries
    }
}

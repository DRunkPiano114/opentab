import Foundation

struct SafariWindowRow: Equatable {
    let windowID: String
    let activeTabIndex: Int
    let tabIndices: [Int]
    let titles: [String]
    let urls: [String]
}

struct ChromiumWindowRow: Equatable {
    let windowID: String
    let mode: String
    let activeTabIndex: Int
    let tabIDs: [String]
    let titles: [String]
    let urls: [String]
}

/// Turns the raw script result into rows. A window whose parallel lists do not
/// line up was mutated mid-read; it is dropped and the other windows are kept,
/// the same way an index-race error code is handled.
enum BrowserScriptParser {
    static func safariWindows(_ value: ScriptValue) -> [SafariWindowRow] {
        (value.items ?? []).compactMap { entry in
            guard let fields = entry.items, fields.count == 5,
                  let windowID = fields[0].string, !windowID.isEmpty,
                  let activeIndex = fields[1].integer else { return nil }
            let indices = (fields[2].items ?? []).map { $0.integer }
            let titles = fields[3].items ?? []
            let urls = fields[4].items ?? []
            guard indices.count == titles.count, titles.count == urls.count,
                  !indices.contains(where: { $0 == nil }) else { return nil }
            return SafariWindowRow(windowID: windowID,
                                   activeTabIndex: activeIndex,
                                   tabIndices: indices.map { $0! },
                                   titles: titles.map { $0.string ?? "" },
                                   urls: urls.map { $0.string ?? "" })
        }
    }

    static func chromiumWindows(_ value: ScriptValue) -> [ChromiumWindowRow] {
        (value.items ?? []).compactMap { entry in
            guard let fields = entry.items, fields.count == 6,
                  let windowID = fields[0].string, !windowID.isEmpty,
                  let mode = fields[1].string,
                  let activeIndex = fields[2].integer else { return nil }
            let ids = fields[3].items ?? []
            let titles = fields[4].items ?? []
            let urls = fields[5].items ?? []
            guard ids.count == titles.count, titles.count == urls.count else { return nil }
            return ChromiumWindowRow(windowID: windowID,
                                     mode: mode,
                                     activeTabIndex: activeIndex,
                                     tabIDs: ids.map { $0.string ?? "" },
                                     titles: titles.map { $0.string ?? "" },
                                     urls: urls.map { $0.string ?? "" })
        }
    }
}

import Foundation

public struct SteamSearchPage: Sendable {
    public let games: [GameMetadata]
    public let nextOffset: Int?

    public init(games: [GameMetadata], nextOffset: Int?) {
        self.games = games
        self.nextOffset = nextOffset
    }

    static func decode(_ data: [String: Any], offset: Int) throws -> SteamSearchPage {
        guard data["success"] as? Int == 1,
              let start = data["start"] as? Int, start == offset,
              let total = data["total_count"] as? Int, total >= 0,
              let html = data["results_html"] as? String else {
            throw AppFailure("搜索分页返回异常，请重试 / Invalid search page; please retry")
        }
        let rows = TextUtil.matches(#"(?si)<a\b[^>]*\bclass\s*=\s*["'][^"']*\bsearch_result_row\b[^"']*["'][^>]*>.*?</a>"#, html)
        if rows.isEmpty && start < total {
            throw AppFailure("搜索结果解析失败，请重试 / Could not read search results; please retry")
        }
        var seen = Set<Int>()
        let games = try rows.compactMap { row -> GameMetadata? in
            let text = row[0]
            // Packages and bundles can contain several AppIDs; only app links are importable.
            guard let rawID = TextUtil.matches(#"(?i)\bhref\s*=\s*["']https://store\.steampowered\.com/app/(\d+)[/"']"#, text).first?[1],
                  let id = TextUtil.validID(rawID) else { return nil }
            guard let title = TextUtil.matches(#"(?si)<span\b[^>]*\bclass=["']title["'][^>]*>(.*?)</span>"#, text).first?[1] else {
                throw AppFailure("搜索结果解析失败，请重试 / Could not read search results; please retry")
            }
            guard seen.insert(id).inserted else { return nil }
            let name = unescape(title.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
            let image = TextUtil.matches(#"(?i)<img\b[^>]*\bsrc=["']([^"']+)["']"#, text).first?[1] ?? ""
            return GameMetadata(id: id, name: name, image: unescape(image),
                                mac: !TextUtil.matches(#"class=["']platform_img mac["']"#, text).isEmpty,
                                windows: !TextUtil.matches(#"class=["']platform_img win["']"#, text).isEmpty)
        }
        let next = start + rows.count
        return SteamSearchPage(games: games, nextOffset: next < total && !rows.isEmpty ? next : nil)
    }

    private static func unescape(_ text: String) -> String {
        let entities = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "ndash": "–", "mdash": "—", "trade": "™", "reg": "®", "copy": "©"]
        let pattern = #"&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let result = NSMutableString(string: text)
        for match in regex.matches(in: text, range: NSRange(location: 0, length: result.length)).reversed() {
            let key = result.substring(with: match.range(at: 1))
            let number = key.hasPrefix("#x") ? UInt32(key.dropFirst(2), radix: 16) : key.hasPrefix("#") ? UInt32(key.dropFirst()) : nil
            let value = number.flatMap(UnicodeScalar.init).map(String.init) ?? entities[key]
            if let value { result.replaceCharacters(in: match.range, with: value) }
        }
        return result as String
    }
}

extension SteamAPI {
    public func searchPage(_ query: String, language: String = "schinese", offset: Int = 0) async throws -> SteamSearchPage {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, offset >= 0 else { return SteamSearchPage(games: [], nextOffset: nil) }
        if let id = TextUtil.validID(query) {
            return SteamSearchPage(games: offset == 0 ? [try await details(id, language: language)] : [], nextOffset: nil)
        }
        // Use Steam's standard 25-row page size; unsupported counts can reset start to zero.
        let url = try HTTP.url("https://store.steampowered.com/search/results/", query: [
            "term": query, "l": language, "cc": "cn", "infinite": "1", "count": "25", "start": String(offset)
        ])
        return try SteamSearchPage.decode(await HTTP.json(url), offset: offset)
    }
}

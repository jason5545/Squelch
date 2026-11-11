import CryptoKit
import Foundation

nonisolated struct SkipSegment: Sendable, Hashable {
    var start: Double
    var end: Double
    var category: String

    var label: String {
        switch category {
        case "sponsor": String(localized: "贊助片段")
        case "selfpromo": String(localized: "自我宣傳")
        case "interaction": String(localized: "訂閱提醒")
        default: category
        }
    }
}

/// SponsorBlock（sponsor.ajay.app）的跳過片段。
/// 用雜湊前綴查詢：只送影片 ID 的 SHA-256 前 4 碼，伺服器不知道你在聽哪一部。
nonisolated enum SponsorBlock {
    static let categories: [(key: String, category: String, title: String, defaultOn: Bool)] = [
        ("sb.sponsor", "sponsor", String(localized: "跳過贊助片段"), true),
        ("sb.selfpromo", "selfpromo", String(localized: "跳過自我宣傳（自家產品、周邊）"), false),
        ("sb.interaction", "interaction", String(localized: "跳過「記得訂閱」提醒"), false),
    ]

    static var enabledCategories: [String] {
        categories.filter { UserDefaults.standard.bool(forKey: $0.key) }.map(\.category)
    }

    static func segments(videoID: String, categories: [String]) async -> [SkipSegment] {
        guard !categories.isEmpty else { return [] }
        let hash = SHA256.hash(data: Data(videoID.utf8)).map { String(format: "%02x", $0) }.joined()
        var components = URLComponents(string: "https://sponsor.ajay.app/api/skipSegments/\(hash.prefix(4))")!
        let list = "[" + categories.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        components.queryItems = [
            URLQueryItem(name: "categories", value: list),
            URLQueryItem(name: "actionTypes", value: "[\"skip\"]"),
        ]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let videos = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        let match = videos.first { ($0["videoID"] as? String) == videoID }
        let raw = match?["segments"] as? [[String: Any]] ?? []
        return raw.compactMap { item in
            guard let pair = item["segment"] as? [NSNumber], pair.count == 2,
                  let category = item["category"] as? String else { return nil }
            let start = pair[0].doubleValue, end = pair[1].doubleValue
            guard end - start > 1 else { return nil }
            return SkipSegment(start: start, end: end, category: category)
        }
        .sorted { $0.start < $1.start }
    }
}

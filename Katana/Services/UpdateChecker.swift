import Foundation

/// Checks the public GitHub Releases feed for a newer Katana version.
enum UpdateChecker: Sendable {
    /// Stable public releases API (JSON). Same data as the Releases page / atom feed.
    nonisolated static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/gingerbeardman/Katana/releases/latest"
    )!

    struct AvailableUpdate: Equatable, Sendable {
        var version: String
        var htmlURL: URL
        var publishedAt: Date?
    }

    struct CheckResult: Sendable {
        var update: AvailableUpdate
        var isNewer: Bool
        var currentVersion: String
    }

    enum CheckError: LocalizedError {
        case noRelease
        case badResponse
        case invalidVersion

        var errorDescription: String? {
            switch self {
            case .noRelease: return "No published releases found."
            case .badResponse: return "Unexpected response from GitHub."
            case .invalidVersion: return "Couldn’t parse the release version."
            }
        }
    }

    /// App marketing version from the bundle (`CFBundleShortVersionString`).
    nonisolated static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "0"
    }

    /// Fetch `releases/latest` and compare to the running app.
    nonisolated static func check() async throws -> CheckResult {
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Katana/\(currentVersion) (macOS)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CheckError.badResponse
        }
        // 404 = no releases published yet.
        if http.statusCode == 404 {
            throw CheckError.noRelease
        }
        guard (200...299).contains(http.statusCode) else {
            throw CheckError.badResponse
        }

        let decoded = try JSONDecoder.github.decode(GitHubRelease.self, from: data)
        guard !decoded.draft, !decoded.prerelease else {
            throw CheckError.noRelease
        }

        let tagVersion = normalizeVersion(decoded.tagName)
        guard !tagVersion.isEmpty else {
            throw CheckError.invalidVersion
        }
        guard let htmlURL = URL(string: decoded.htmlURL) else {
            throw CheckError.badResponse
        }

        let current = normalizeVersion(currentVersion)
        let update = AvailableUpdate(
            version: tagVersion,
            htmlURL: htmlURL,
            publishedAt: decoded.publishedAt
        )
        return CheckResult(
            update: update,
            isNewer: compareVersions(tagVersion, current) == .orderedDescending,
            currentVersion: current
        )
    }

    /// Strip a leading `v` and whitespace (`v1.2.0` → `1.2.0`).
    nonisolated static func normalizeVersion(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > 1, s.lowercased().hasPrefix("v"), s.dropFirst().first?.isNumber == true {
            s = String(s.dropFirst())
        }
        // Prefer the first token that looks like a version (handles "1.2 — notes").
        if let token = s.split(whereSeparator: { $0.isWhitespace || $0 == "—" || $0 == "-" }).first,
           token.contains(where: \.isNumber)
        {
            return String(token)
        }
        return s
    }

    /// Numeric component compare: `1.10` > `1.9`; unequal length pads with 0.
    nonisolated static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = versionComponents(lhs)
        let right = versionComponents(rhs)
        let count = max(left.count, right.count)
        for i in 0..<count {
            let a = i < left.count ? left[i] : 0
            let b = i < right.count ? right[i] : 0
            if a != b {
                return a < b ? .orderedAscending : .orderedDescending
            }
        }
        return .orderedSame
    }

    nonisolated private static func versionComponents(_ version: String) -> [Int] {
        version.split(separator: ".").map { part in
            let digits = part.prefix(while: \.isNumber)
            return Int(digits) ?? 0
        }
    }
}

// MARK: - GitHub API

private struct GitHubRelease: Decodable, Sendable {
    var tagName: String
    var htmlURL: String
    var draft: Bool
    var prerelease: Bool
    var publishedAt: Date?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case draft
        case prerelease
        case publishedAt = "published_at"
    }
}

private extension JSONDecoder {
    static let github: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

import Foundation

/// Normalizes source JSON while preserving download URLs as entered.
enum SideStoreJSONFormatter {
    static func encode(_ source: Source, preserving originalData: Data?) throws -> Data {
        let original = originalData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        var result = original
        update(&result, from: source, keys: ["name", "subtitle", "description", "iconURL", "tintColor", "featuredApps", "headerURL", "website", "fediUsername", "identifier"])
        result["name"] = source.name
        result["subtitle"] = source.subtitle
        result["description"] = source.sourceDescription
        result["iconURL"] = source.iconURL
        result["tintColor"] = source.tintColor
        result["featuredApps"] = source.featuredApps
        result["apps"] = source.apps.map { app in
            let old = (original["apps"] as? [[String: Any]])?.first { ($0["bundleIdentifier"] as? String) == app.bundleIdentifier } ?? [:]
            return format(app, preserving: old)
        }
        result["news"] = source.news.map { item in
            let old = (original["news"] as? [[String: Any]])?.first { ($0["identifier"] as? String) == item.identifier } ?? [:]
            return format(item, preserving: old)
        }
        if source.identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let slug = source.name.lowercased().unicodeScalars.map { scalar in
                (scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 48 && scalar.value <= 57) ? String(scalar) : "-"
            }.joined()
                .split(separator: "-").joined(separator: "-")
            result["identifier"] = "com.\(slug.isEmpty ? "source" : slug).repository"
        }
        for key in ["patreonURL", "patreon"] { result.removeValue(forKey: key) }
        removeEmpty(&result, key: "headerURL")
        return try orderedJSONData(result)
    }

    /// Keep source metadata above apps/news, and each app's permissions last.
    private static func orderedJSONData(_ value: Any) throws -> Data {
        func scalar(_ value: Any) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
            return String(decoding: data, as: UTF8.self)
        }
        func render(_ value: Any, depth: Int, path: [String]) throws -> String {
            let indent = String(repeating: "  ", count: depth)
            let nextIndent = indent + "  "
            if let object = value as? [String: Any] {
                guard !object.isEmpty else { return "{}" }
                var keys = object.keys.sorted()
                if path.isEmpty {
                    let first = ["name", "identifier", "subtitle", "description", "iconURL", "headerURL",
                                 "website", "tintColor", "fediUsername", "featuredApps"]
                    let last = ["apps", "news"]
                    keys = first.filter { object[$0] != nil }
                        + keys.filter { !first.contains($0) && !last.contains($0) }
                        + last.filter { object[$0] != nil }
                } else if path == ["apps", "[]"] {
                    let first = ["name", "bundleIdentifier", "developerName", "subtitle", "localizedDescription",
                                 "iconURL", "tintColor", "category", "screenshots", "versions"]
                    keys = first.filter { object[$0] != nil }
                        + keys.filter { !first.contains($0) && $0 != "appPermissions" }
                        + (object["appPermissions"] == nil ? [] : ["appPermissions"])
                }
                let rows = try keys.map { key in
                    nextIndent + (try scalar(key)) + " : "
                        + (try render(object[key]!, depth: depth + 1, path: path + [key]))
                }
                return "{\n" + rows.joined(separator: ",\n") + "\n" + indent + "}"
            }
            if let array = value as? [Any] {
                guard !array.isEmpty else { return "[]" }
                let rows = try array.map { nextIndent + (try render($0, depth: depth + 1, path: path + ["[]"])) }
                return "[\n" + rows.joined(separator: ",\n") + "\n" + indent + "]"
            }
            return try scalar(value)
        }
        return Data(try render(value, depth: 0, path: []).utf8)
    }

    private static func format(_ app: SourceApp, preserving original: [String: Any]) -> [String: Any] {
        var result = original
        update(&result, from: app, keys: ["name", "bundleIdentifier", "developerName", "subtitle", "localizedDescription", "iconURL", "tintColor", "category", "screenshots"])
        result["name"] = app.name
        result["bundleIdentifier"] = app.bundleIdentifier
        result["developerName"] = app.developerName
        result["subtitle"] = app.subtitle
        result["localizedDescription"] = app.localizedDescription
        result["iconURL"] = app.iconURL
        result["tintColor"] = app.tintColor
        result["category"] = app.category
        if result["screenshots"] == nil { result["screenshots"] = [String]() }
        result["appPermissions"] = permissions(app.appPermissions, preserving: original["appPermissions"] as? [String: Any] ?? [:])
        result["versions"] = app.versions.map { version in
            let old = (original["versions"] as? [[String: Any]])?.first { ($0["version"] as? String) == version.version } ?? [:]
            return format(version, preserving: old)
        }.sorted { versionNumbers($0["version"] as? String ?? "").lexicographicallyPrecedes(versionNumbers($1["version"] as? String ?? ""), by: >) }
        for key in ["marketplaceID", "Build", "patreon", "iconPreviewData"] { result.removeValue(forKey: key) }
        return result
    }

    private static func format(_ version: SourceVersion, preserving original: [String: Any]) -> [String: Any] {
        var result = original
        update(&result, from: version, keys: ["version", "date", "localizedDescription", "downloadURL", "size", "minOSVersion", "maxOSVersion", "marketingVersion", "assetURLs"])
        result["version"] = version.version
        result["date"] = normalizedDate(version.date)
        result["localizedDescription"] = version.localizedDescription
        result["downloadURL"] = version.downloadURL
        result["size"] = version.size
        result["minOSVersion"] = version.minOSVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "16.1" : version.minOSVersion
        result.removeValue(forKey: "buildVersion")
        return result
    }

    private static func format(_ news: SourceNews, preserving original: [String: Any]) -> [String: Any] {
        var result = original
        update(&result, from: news, keys: ["title", "identifier", "caption", "date", "tintColor", "imageURL", "notify", "appID"])
        result["title"] = news.title
        result["identifier"] = news.identifier
        result["caption"] = news.caption
        result["date"] = normalizedDate(news.date)
        result["notify"] = news.notify
        result.removeValue(forKey: "url")
        removeEmpty(&result, key: "imageURL")
        return result
    }

    private static func permissions(_ current: AppPermissions, preserving original: [String: Any]) -> [String: Any] {
        var result = original
        result["entitlements"] = current.entitlements
        result["privacy"] = current.privacy
        return result
    }

    private static func update<T: Encodable>(_ result: inout [String: Any], from value: T, keys: [String]) {
        guard let data = try? JSONEncoder().encode(value),
              let current = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        for key in keys {
            if let field = current[key] { result[key] = field }
            else { result.removeValue(forKey: key) }
        }
    }

    private static func removeEmpty(_ value: inout [String: Any], key: String) {
        if (value[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { value.removeValue(forKey: key) }
    }

    private static func versionNumbers(_ version: String) -> [Int] {
        version.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }

    private static func normalizedDate(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let utc = ISO8601DateFormatter()
        utc.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        let date: Date?
        if let parsed = utc.date(from: trimmed) ?? plain.date(from: trimmed) {
            date = parsed
        } else {
            let day = DateFormatter()
            day.locale = Locale(identifier: "en_US_POSIX")
            day.timeZone = TimeZone(secondsFromGMT: 9 * 3600)
            day.dateFormat = "yyyy-MM-dd"
            date = day.date(from: String(trimmed.prefix(10)))
        }
        guard let date else { return trimmed }
        let output = ISO8601DateFormatter()
        output.timeZone = TimeZone(secondsFromGMT: 9 * 3600)
        output.formatOptions = [.withInternetDateTime]
        return output.string(from: date)
    }
}

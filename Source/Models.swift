import Foundation

private extension KeyedDecodingContainer {
    func string(_ key: Key) -> String { (try? decodeIfPresent(String.self, forKey: key)) ?? "" }
    func items<T: Decodable>(_ key: Key) -> [T] { (try? decodeIfPresent([T].self, forKey: key)) ?? [] }
}

private extension KeyedEncodingContainer {
    mutating func nonempty(_ value: String, forKey key: Key) throws {
        if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { try encode(value, forKey: key) }
    }
}

struct Source: Codable, Equatable {
    var name = "My Source"
    var identifier = ""
    var subtitle = ""
    var sourceDescription = ""
    var iconURL = ""
    var headerURL = ""
    var website = ""
    var fediUsername = ""
    var patreonURL = ""
    var tintColor = ""
    var featuredApps: [String] = []
    var apps: [SourceApp] = []
    var news: [SourceNews] = []

    enum CodingKeys: String, CodingKey {
        case name, identifier, subtitle, iconURL, headerURL, website, fediUsername, patreonURL, tintColor, featuredApps, apps, news
        case sourceDescription = "description"
    }

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.string(.name); identifier = c.string(.identifier); subtitle = c.string(.subtitle); sourceDescription = c.string(.sourceDescription)
        iconURL = c.string(.iconURL); headerURL = c.string(.headerURL); website = c.string(.website)
        fediUsername = c.string(.fediUsername); patreonURL = c.string(.patreonURL); tintColor = c.string(.tintColor)
        featuredApps = c.items(.featuredApps); apps = c.items(.apps); news = c.items(.news)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.nonempty(identifier, forKey: .identifier)
        try c.nonempty(subtitle, forKey: .subtitle); try c.nonempty(sourceDescription, forKey: .sourceDescription)
        try c.nonempty(iconURL, forKey: .iconURL); try c.nonempty(headerURL, forKey: .headerURL)
        try c.nonempty(website, forKey: .website); try c.nonempty(fediUsername, forKey: .fediUsername)
        try c.nonempty(patreonURL, forKey: .patreonURL); try c.nonempty(tintColor, forKey: .tintColor)
        if !featuredApps.isEmpty { try c.encode(featuredApps, forKey: .featuredApps) }
        try c.encode(apps, forKey: .apps); try c.encode(news, forKey: .news)
    }
}

struct SourceApp: Codable, Equatable {
    // Stable identity for animated row moves; intentionally omitted from source JSON.
    var editorID = UUID()
    var name = ""
    var bundleIdentifier = ""
    var developerName = ""
    var subtitle = ""
    var localizedDescription = ""
    var iconURL = ""
    // Kept in the local draft for preview/export. Source JSON still requires a hosted iconURL.
    var iconPreviewData: Data?
    var tintColor = ""
    var category = "other"
    var screenshots = AppScreenshots()
    var versions: [SourceVersion] = []
    var appPermissions = AppPermissions()
    var patreon = Patreon()

    enum CodingKeys: String, CodingKey { case name, bundleIdentifier, developerName, subtitle, localizedDescription, iconURL, iconPreviewData, tintColor, category, screenshots, versions, appPermissions, patreon }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.string(.name); bundleIdentifier = c.string(.bundleIdentifier)
        developerName = c.string(.developerName); subtitle = c.string(.subtitle)
        localizedDescription = c.string(.localizedDescription); iconURL = c.string(.iconURL)
        iconPreviewData = try? c.decodeIfPresent(Data.self, forKey: .iconPreviewData)
        tintColor = c.string(.tintColor); category = c.string(.category)
        if category.isEmpty { category = "other" }
        screenshots = (try? c.decodeIfPresent(AppScreenshots.self, forKey: .screenshots)) ?? AppScreenshots()
        versions = c.items(.versions)
        appPermissions = (try? c.decodeIfPresent(AppPermissions.self, forKey: .appPermissions)) ?? AppPermissions()
        patreon = (try? c.decodeIfPresent(Patreon.self, forKey: .patreon)) ?? Patreon()
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name); try c.encode(bundleIdentifier, forKey: .bundleIdentifier)
        try c.encode(developerName, forKey: .developerName)
        try c.nonempty(subtitle, forKey: .subtitle); try c.encode(localizedDescription, forKey: .localizedDescription)
        try c.encode(iconURL, forKey: .iconURL); try c.nonempty(tintColor, forKey: .tintColor)
        try c.encodeIfPresent(iconPreviewData, forKey: .iconPreviewData)
        try c.nonempty(category, forKey: .category)
        if !screenshots.iphone.isEmpty || !screenshots.ipad.isEmpty { try c.encode(screenshots, forKey: .screenshots) }
        try c.encode(versions, forKey: .versions)
        try c.encode(appPermissions, forKey: .appPermissions)
        if !patreon.isEmpty { try c.encode(patreon, forKey: .patreon) }
    }
}

struct Screenshot: Codable, Equatable {
    // Stable editor identity for asynchronous image uploads; not exported to JSON.
    var editorID = UUID()
    var imageURL = ""
    var width = ""
    var height = ""
    enum CodingKeys: String, CodingKey { case imageURL, width, height }
    init() {}
    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let value = try? single.decode(String.self) {
            imageURL = value; return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        imageURL = c.string(.imageURL)
        if let value = try? c.decode(Int.self, forKey: .width) { width = String(value) }
        if let value = try? c.decode(Int.self, forKey: .height) { height = String(value) }
    }
    func encode(to encoder: Encoder) throws {
        if width.isEmpty && height.isEmpty {
            var c = encoder.singleValueContainer(); try c.encode(imageURL); return
        }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(imageURL, forKey: .imageURL)
        if let n = Int(width) { try c.encode(n, forKey: .width) }
        if let n = Int(height) { try c.encode(n, forKey: .height) }
    }
}

struct AppScreenshots: Codable, Equatable {
    var iphone: [Screenshot] = []
    var ipad: [Screenshot] = []
    enum CodingKeys: String, CodingKey { case iphone, ipad }
    init() {}
    init(from decoder: Decoder) throws {
        if let array = try? decoder.singleValueContainer().decode([Screenshot].self) { iphone = array; return }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        iphone = c.items(.iphone); ipad = c.items(.ipad)
    }
    func encode(to encoder: Encoder) throws {
        if ipad.isEmpty {
            var c = encoder.singleValueContainer(); try c.encode(iphone); return
        }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(iphone, forKey: .iphone); try c.encode(ipad, forKey: .ipad)
    }
}

struct SourceVersion: Codable, Equatable {
    var version = ""
    var buildVersion = ""
    var marketingVersion = ""
    var date = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))
    var localizedDescription = ""
    var downloadURL = ""
    var size = 0
    var minOSVersion = ""
    var maxOSVersion = ""
    var assetURLs: [String: String] = [:]
    enum CodingKeys: String, CodingKey { case version, buildVersion, marketingVersion, date, localizedDescription, downloadURL, size, minOSVersion, maxOSVersion, assetURLs }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.string(.version); buildVersion = c.string(.buildVersion); marketingVersion = c.string(.marketingVersion)
        date = c.string(.date); localizedDescription = c.string(.localizedDescription); downloadURL = c.string(.downloadURL)
        size = (try? c.decode(Int.self, forKey: .size)) ?? 0
        minOSVersion = c.string(.minOSVersion); maxOSVersion = c.string(.maxOSVersion)
        assetURLs = (try? c.decode([String: String].self, forKey: .assetURLs)) ?? [:]
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version); try c.nonempty(buildVersion, forKey: .buildVersion)
        try c.nonempty(marketingVersion, forKey: .marketingVersion); try c.encode(date, forKey: .date)
        try c.nonempty(localizedDescription, forKey: .localizedDescription)
        try c.encode(downloadURL, forKey: .downloadURL); try c.encode(size, forKey: .size)
        try c.nonempty(minOSVersion, forKey: .minOSVersion); try c.nonempty(maxOSVersion, forKey: .maxOSVersion)
        if !assetURLs.isEmpty { try c.encode(assetURLs, forKey: .assetURLs) }
    }
}

struct AppPermissions: Codable, Equatable {
    var entitlements: [String] = []
    var privacy: [String: String] = [:]
}

struct Patreon: Codable, Equatable {
    var pledge = ""
    var currency = ""
    var benefit = ""
    var tiers: [String] = []
    var isEmpty: Bool { pledge.isEmpty && currency.isEmpty && benefit.isEmpty && tiers.isEmpty }
    enum CodingKeys: String, CodingKey { case pledge, currency, benefit, tiers }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? c.decode(Double.self, forKey: .pledge) { pledge = String(value) }
        currency = c.string(.currency); benefit = c.string(.benefit); tiers = c.items(.tiers)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let n = Double(pledge) { try c.encode(n, forKey: .pledge) }
        try c.nonempty(currency, forKey: .currency); try c.nonempty(benefit, forKey: .benefit)
        if !tiers.isEmpty { try c.encode(tiers, forKey: .tiers) }
    }
}

struct SourceNews: Codable, Equatable {
    // Stable navigation identity, omitted from source JSON like app editor identities.
    var editorID = UUID()
    var title = ""
    var identifier = ""
    var caption = ""
    var date = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))
    var tintColor = ""
    var imageURL = ""
    var notify = false
    var url = ""
    var appID = ""
    enum CodingKeys: String, CodingKey { case title, identifier, caption, date, tintColor, imageURL, notify, url, appID }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = c.string(.title); identifier = c.string(.identifier); caption = c.string(.caption); date = c.string(.date)
        tintColor = c.string(.tintColor); imageURL = c.string(.imageURL)
        notify = (try? c.decode(Bool.self, forKey: .notify)) ?? false
        url = c.string(.url); appID = c.string(.appID)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title); try c.encode(identifier, forKey: .identifier)
        try c.encode(caption, forKey: .caption); try c.encode(date, forKey: .date)
        try c.nonempty(tintColor, forKey: .tintColor); try c.nonempty(imageURL, forKey: .imageURL)
        if notify { try c.encode(notify, forKey: .notify) }
        try c.nonempty(url, forKey: .url); try c.nonempty(appID, forKey: .appID)
    }
}

import Foundation
import UIKit
import ZIPFoundation

struct ScannedAppPackage {
    var fileName: String
    var size: Int
    var name: String = ""
    var bundleIdentifier: String = ""
    var version: String = ""
    var buildVersion: String = ""
    var minOSVersion: String = ""
    var iconData: Data?
    var tintColor = ""
    var privacy: [String: String] = [:]
}

enum AppPackageScanner {
    private static let maxMetadataBytes = 2_000_000
    private static let maxIconBytes = 8_000_000
    private static let maxAssetsBytes = 40_000_000
    private static let maxVariantBytes = 250_000_000

    static func scan(_ url: URL) throws -> ScannedAppPackage {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }

        let ext = url.pathExtension.lowercased()
        guard ext == "ipa" || ext == "adp" else { throw ScanError.unsupportedType }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw CocoaError(.fileReadNoSuchFile)
        }

        if isDirectory.boolValue {
            guard ext == "adp" else { throw ScanError.invalidPackage }
            return try scanADPDirectory(url)
        }

        let size = try fileSize(url)
        let archive = try Archive(url: url, accessMode: .read)
        if ext == "ipa" { return try scanIPA(archive, fileName: url.lastPathComponent, size: size) }
        return try scanADPArchive(archive, fileName: url.lastPathComponent, size: size)
    }

    private static func scanIPA(_ archive: Archive, fileName: String, size: Int) throws -> ScannedAppPackage {
        guard let infoEntry = archive.first(where: { entry in
            let parts = entry.path.split(separator: "/")
            return parts.count == 3 && parts[0] == "Payload" && parts[1].hasSuffix(".app") && parts[2] == "Info.plist"
        }) else { throw ScanError.missingInfo }

        let infoData = try read(infoEntry, from: archive, limit: maxMetadataBytes)
        guard let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any] else {
            throw ScanError.invalidPackage
        }
        let root = String(infoEntry.path.dropLast("Info.plist".count))
        var result = ScannedAppPackage(fileName: fileName, size: size)
        result.name = firstString(info, ["CFBundleDisplayName", "CFBundleName"])
        if result.name.isEmpty || result.name.contains("$(") {
            result.name = String(infoEntry.path.split(separator: "/")[1].dropLast(4))
        }
        result.bundleIdentifier = firstString(info, ["CFBundleIdentifier"])
        result.version = firstString(info, ["CFBundleShortVersionString"])
        result.buildVersion = firstString(info, ["CFBundleVersion"])
        result.minOSVersion = firstString(info, ["MinimumOSVersion"])
        result.iconData = iconData(in: archive, root: root, info: info, infoData: infoData)
        result.privacy = info.reduce(into: [:]) { values, entry in
            if entry.key.hasPrefix("NS"), entry.key.hasSuffix("UsageDescription"),
               let value = entry.value as? String, !value.isEmpty { values[entry.key] = value }
        }
        if let data = result.iconData { result.tintColor = suggestedTint(from: data) }
        return result
    }

    private static func scanADPArchive(_ archive: Archive, fileName: String, size: Int) throws -> ScannedAppPackage {
        guard let manifestEntry = archive.first(where: { $0.path == "manifest.json" || $0.path.hasSuffix("/manifest.json") }) else {
            throw ScanError.missingManifest
        }
        let manifestData = try read(manifestEntry, from: archive, limit: maxMetadataBytes)
        var result = try scanManifest(manifestData, fileName: fileName, size: size)
        if let variant = firstVariantPath(manifestData),
           let variantEntry = archive.first(where: { $0.path == variant || $0.path.hasSuffix("/" + variant) }),
           Int(variantEntry.uncompressedSize) <= maxVariantBytes {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ipa")
            defer { try? FileManager.default.removeItem(at: temporary) }
            if (try? archive.extract(variantEntry, to: temporary)) != nil,
               let nested = try? Archive(url: temporary, accessMode: .read, pathEncoding: nil),
               let scanned = try? scanIPA(nested, fileName: fileName, size: result.size) {
                mergeAppDetails(from: scanned, into: &result)
            }
        }
        return result
    }

    private static func scanADPDirectory(_ url: URL) throws -> ScannedAppPackage {
        let manifestURL = url.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        guard data.count <= maxMetadataBytes else { throw ScanError.fileTooLarge }
        var result = try scanManifest(data, fileName: url.lastPathComponent, size: 0)
        if let variant = firstVariantPath(data) {
            let variantURL = url.appendingPathComponent(variant)
            if let size = try? fileSize(variantURL), size <= maxVariantBytes,
               let archive = try? Archive(url: variantURL, accessMode: .read, pathEncoding: nil),
               let scanned = try? scanIPA(archive, fileName: url.lastPathComponent, size: result.size) {
                mergeAppDetails(from: scanned, into: &result)
            }
        }
        return result
    }

    private static func scanManifest(_ data: Data, fileName: String, size: Int) throws -> ScannedAppPackage {
        guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              manifest["bundleId"] is String else { throw ScanError.missingManifest }
        var result = ScannedAppPackage(fileName: fileName, size: size)
        result.bundleIdentifier = manifest["bundleId"] as? String ?? ""
        result.version = manifest["shortVersionString"] as? String ?? ""
        result.buildVersion = manifest["bundleVersion"] as? String ?? ""
        result.minOSVersion = (manifest["minimumSystemVersions"] as? [String: String])?["ios"] ?? ""
        result.name = (manifest["name"] as? String) ?? (manifest["appName"] as? String) ?? ""
        if let variant = (manifest["variants"] as? [[String: Any]])?.first,
           let details = variant["variantDetails"] as? [String: Any],
           let compressed = details["compressedSize"] as? NSNumber {
            result.size = compressed.intValue
        }
        return result
    }

    private static func firstVariantPath(_ data: Data) -> String? {
        guard let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (manifest["variants"] as? [[String: Any]])?.compactMap { $0["assetPath"] as? String }.first
    }

    private static func mergeAppDetails(from nested: ScannedAppPackage, into result: inout ScannedAppPackage) {
        if result.name.isEmpty { result.name = nested.name }
        if result.bundleIdentifier.isEmpty { result.bundleIdentifier = nested.bundleIdentifier }
        if result.version.isEmpty { result.version = nested.version }
        if result.buildVersion.isEmpty { result.buildVersion = nested.buildVersion }
        if result.minOSVersion.isEmpty { result.minOSVersion = nested.minOSVersion }
        result.iconData = nested.iconData
        if result.tintColor.isEmpty { result.tintColor = nested.tintColor }
        result.privacy.merge(nested.privacy) { current, _ in current }
    }

    private static func suggestedTint(from data: Data) -> String {
        guard let image = UIImage(data: data)?.cgImage else { return "" }
        var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 32, height: 32,
                bitsPerComponent: 8, bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            return true
        }
        guard drawn else { return "" }
        var buckets: [Int: (count: Int, r: Int, g: Int, b: Int)] = [:]
        var total = (count: 0, r: 0, g: 0, b: 0)
        for offset in stride(from: 0, to: pixels.count, by: 4) where pixels[offset + 3] >= 200 {
            let r = Int(pixels[offset]), g = Int(pixels[offset + 1]), b = Int(pixels[offset + 2])
            total = (total.count + 1, total.r + r, total.g + g, total.b + b)
            let maximum = max(r, max(g, b)), minimum = min(r, min(g, b))
            guard maximum >= 64, maximum - minimum >= maximum / 4 else { continue }
            let key = (r >> 4) << 8 | (g >> 4) << 4 | (b >> 4)
            let old = buckets[key] ?? (count: 0, r: 0, g: 0, b: 0)
            buckets[key] = (old.count + 1, old.r + r, old.g + g, old.b + b)
        }
        let color = buckets.max { left, right in
            left.value.count == right.value.count ? left.key < right.key : left.value.count < right.value.count
        }?.value ?? total
        guard color.count > 0 else { return "" }
        return String(format: "#%02x%02x%02x", color.r / color.count, color.g / color.count, color.b / color.count)
    }

    private static func iconData(in archive: Archive, root: String, info: [String: Any], infoData: Data) -> Data? {
        var names: [String] = []
        for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            if let icons = info[key] as? [String: Any],
               let primary = icons["CFBundlePrimaryIcon"] as? [String: Any] {
                names += primary["CFBundleIconFiles"] as? [String] ?? []
                if let name = primary["CFBundleIconName"] as? String { names.append(name) }
            }
        }
        names += info["CFBundleIconFiles"] as? [String] ?? []
        if let name = info["CFBundleIconFile"] as? String { names.append(name) }
        let prefixes = names.map { $0.lowercased().replacingOccurrences(of: ".png", with: "") }

        let candidates = archive.filter { entry in
            guard entry.path.hasPrefix(root), entry.type == .file,
                  Int(entry.uncompressedSize) <= maxIconBytes else { return false }
            let remainder = entry.path.dropFirst(root.count)
            return !remainder.contains("/") && ["png", "jpg", "jpeg"].contains((entry.path as NSString).pathExtension.lowercased())
        }.sorted { left, right in
            let leftScore = iconScore(left.path, prefixes: prefixes)
            let rightScore = iconScore(right.path, prefixes: prefixes)
            return leftScore == rightScore ? left.uncompressedSize > right.uncompressedSize : leftScore > rightScore
        }
        for entry in candidates where iconScore(entry.path, prefixes: prefixes) > 0 {
            if let data = try? read(entry, from: archive, limit: maxIconBytes),
               let image = UIImage(data: data) {
                return normalizedIcon(image)
            }
        }

        guard let assets = archive.first(where: { $0.path == root + "Assets.car" }),
              Int(assets.uncompressedSize) <= maxAssetsBytes else { return nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bundleURL = directory.appendingPathComponent("Scanned.app")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
            try infoData.write(to: bundleURL.appendingPathComponent("Info.plist"))
            _ = try archive.extract(assets, to: bundleURL.appendingPathComponent("Assets.car"))
            guard let bundle = Bundle(url: bundleURL) else { return nil }
            for name in names + ["AppIcon"] {
                if let image = UIImage(named: name, in: bundle, compatibleWith: nil) { return normalizedIcon(image) }
            }
        } catch { return nil }
        return nil
    }

    private static func iconScore(_ path: String, prefixes: [String]) -> Int {
        let name = (path as NSString).lastPathComponent.lowercased()
        if prefixes.contains(where: { name.hasPrefix($0) }) { return 100 }
        if name.contains("appicon") { return 80 }
        if name.contains("itunesartwork") { return 60 }
        return 0
    }

    private static func normalizedIcon(_ image: UIImage) -> Data? {
        let edge: CGFloat = 256
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: edge, height: edge))
        return renderer.pngData { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: edge, height: edge))
        }
    }

    private static func read(_ entry: Entry, from archive: Archive, limit: Int) throws -> Data {
        guard Int(entry.uncompressedSize) <= limit else { throw ScanError.fileTooLarge }
        var data = Data()
        _ = try archive.extract(entry, consumer: { chunk in
            guard data.count + chunk.count <= limit else { throw ScanError.fileTooLarge }
            data.append(chunk)
        })
        return data
    }

    private static func firstString(_ dictionary: [String: Any], _ keys: [String]) -> String {
        for key in keys {
            if let value = dictionary[key] as? String, !value.isEmpty { return value }
        }
        return ""
    }

    private static func fileSize(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.intValue ?? 0
    }
}

private enum ScanError: LocalizedError {
    case unsupportedType, invalidPackage, missingInfo, missingManifest, fileTooLarge

    var errorDescription: String? {
        switch self {
        case .unsupportedType: "IPA 또는 ADP 파일을 선택하세요."
        case .invalidPackage: "파일에서 앱 정보를 읽을 수 없습니다."
        case .missingInfo: "IPA에 앱 Info.plist가 없습니다."
        case .missingManifest: "ADP에 manifest.json이 없습니다."
        case .fileTooLarge: "패키지의 메타데이터 또는 아이콘이 너무 큽니다."
        }
    }
}

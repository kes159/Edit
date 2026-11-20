import Foundation
import SwiftUI
import UniformTypeIdentifiers

final class SourceStore: ObservableObject {
    private var importedJSON: Data?
    @Published var source: AltSource {
        didSet { save() }
    }
    @Published var message: String?
    var hasSavedDraft: Bool { UserDefaults.standard.data(forKey: "altSourceDraft") != nil }

    init() {
        importedJSON = UserDefaults.standard.data(forKey: "altSourceImportedJSON")
        if let data = UserDefaults.standard.data(forKey: "altSourceDraft"),
           let loaded = try? JSONDecoder().decode(AltSource.self, from: data) {
            source = loaded
        } else {
            source = AltSource()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(source) {
            UserDefaults.standard.set(data, forKey: "altSourceDraft")
        }
    }

    func newProject() {
        importedJSON = nil
        UserDefaults.standard.removeObject(forKey: "altSourceImportedJSON")
        source = AltSource()
    }

    func jsonData() -> Data {
        (try? SideStoreJSONFormatter.encode(source, preserving: importedJSON)) ?? Data("{}".utf8)
    }

    var jsonText: String { String(data: jsonData(), encoding: .utf8) ?? "{}" }

    @discardableResult
    func importJSON(_ url: URL) -> Bool {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        do {
            return importJSON(try Data(contentsOf: url))
        } catch {
            message = "JSON 파일을 열지 못했습니다: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func importJSON(_ data: Data) -> Bool {
        do {
            applyImportedJSON(try Self.decodeJSON(data), data: data)
            return true
        } catch {
            message = "JSON을 읽지 못했습니다: \(error.localizedDescription)"
            return false
        }
    }

    static func decodeJSON(_ data: Data) throws -> AltSource {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["name"] is String,
              object["apps"] is [Any],
              (object["news"] == nil || object["news"] is [Any]) else {
            throw ImportFailure.invalidAltSource
        }
        return try JSONDecoder().decode(AltSource.self, from: data)
    }

    func applyImportedJSON(_ imported: AltSource, data: Data) {
        importedJSON = data
        UserDefaults.standard.set(data, forKey: "altSourceImportedJSON")
        source = imported
        message = "JSON을 가져왔습니다."
    }

    var issues: [String] {
        var result: [String] = []
        if source.name.trimmed.isEmpty { result.append("소스 이름을 입력하세요.") }
        let bundleIDs = source.apps.map(\.bundleIdentifier).filter { !$0.trimmed.isEmpty }
        if Set(bundleIDs).count != bundleIDs.count { result.append("앱의 Bundle ID가 중복됩니다.") }
        for (index, app) in source.apps.enumerated() {
            let label = "앱 \(index + 1)"
            if app.name.trimmed.isEmpty { result.append("\(label): 이름이 없습니다.") }
            if app.bundleIdentifier.trimmed.isEmpty { result.append("\(label): Bundle ID가 없습니다.") }
            if app.developerName.trimmed.isEmpty { result.append("\(label): 개발자 이름이 없습니다.") }
            if app.iconURL.trimmed.isEmpty { result.append("\(label): 아이콘 URL이 없습니다.") }
            if app.versions.isEmpty { result.append("\(label): 버전이 없습니다.") }
            for (vIndex, version) in app.versions.enumerated() {
                let vLabel = "\(label) 버전 \(vIndex + 1)"
                if version.version.trimmed.isEmpty { result.append("\(vLabel): 버전 번호가 없습니다.") }
                if version.downloadURL.trimmed.isEmpty { result.append("\(vLabel): 다운로드 URL이 없습니다.") }
                if version.size <= 0 { result.append("\(vLabel): 파일 크기를 바이트 단위로 입력하세요.") }
            }
            for screenshot in app.screenshots.ipad where Int(screenshot.width) == nil || Int(screenshot.height) == nil {
                result.append("\(label): iPad 스크린샷에는 너비와 높이가 필요합니다.")
            }
        }
        let newsIDs = source.news.map(\.identifier).filter { !$0.trimmed.isEmpty }
        if Set(newsIDs).count != newsIDs.count { result.append("뉴스 식별자가 중복됩니다.") }
        for (index, item) in source.news.enumerated() {
            if item.title.trimmed.isEmpty || item.identifier.trimmed.isEmpty || item.caption.trimmed.isEmpty {
                result.append("뉴스 \(index + 1): 제목, 식별자, 뉴스 내용이 필요합니다.")
            }
        }
        return result
    }
}

private enum ImportFailure: LocalizedError {
    case invalidAltSource
    var errorDescription: String? {
        "AltSource JSON에는 name과 apps 항목이 필요합니다."
    }
}

private extension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }

struct JSONFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct PNGFile: FileDocument {
    static var readableContentTypes: [UTType] { [.png] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

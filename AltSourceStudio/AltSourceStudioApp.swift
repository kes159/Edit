import SwiftUI
import UniformTypeIdentifiers

@main
struct AltSourceStudioApp: App {
    @StateObject private var store = SourceStore()
    var body: some Scene { WindowGroup { RootView().environmentObject(store) } }
}

struct RootView: View {
    @EnvironmentObject private var store: SourceStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var importing = false
    @State private var exporting = false
    @State private var exportDocument: JSONFile?
    @State private var selectedSection: EditorSection? = .source
    @State private var splitVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        Group {
            if UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular {
                iPadLayout
            } else {
                compactLayout
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): store.importJSON(url)
            case .failure(let error): store.message = error.localizedDescription
            }
        }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json,
                      defaultFilename: "AltSource.json") { result in
            if case .failure(let error) = result { store.message = error.localizedDescription }
        }
        .alert("AltSource Studio", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            Button("확인", role: .cancel) { store.message = nil }
        } message: { Text(store.message ?? "") }
    }

    private var compactLayout: some View {
        TabView {
            NavigationStack { SourceEditor() }
                .tabItem { Label("소스", systemImage: "square.stack.3d.up") }
            NavigationStack { AppsScreen() }
                .tabItem { Label("앱", systemImage: "apps.iphone") }
            NavigationStack { NewsScreen() }
                .tabItem { Label("뉴스", systemImage: "newspaper") }
            NavigationStack { jsonScreen }
                .tabItem { Label("JSON", systemImage: "curlybraces") }
        }
    }

    private var iPadLayout: some View {
        NavigationSplitView(columnVisibility: $splitVisibility) {
            List(EditorSection.allCases, selection: $selectedSection) { section in
                Label(section.title, systemImage: section.icon)
                    .tag(section)
            }
            .navigationTitle("AltSource Studio")
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom) {
                Text("앱 \(store.source.apps.count)개 · 뉴스 \(store.source.news.count)개")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        } detail: {
            NavigationStack {
                switch selectedSection ?? .source {
                case .source: SourceEditor()
                case .apps: AppsScreen()
                case .news: NewsScreen()
                case .json: jsonScreen
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var jsonScreen: some View {
        JSONScreen(importAction: { importing = true }, exportAction: {
            exportDocument = JSONFile(data: store.jsonData())
            exporting = true
        })
    }
}

private enum EditorSection: String, CaseIterable, Identifiable {
    case source, apps, news, json
    var id: Self { self }
    var title: String {
        switch self {
        case .source: "소스 설정"
        case .apps: "앱"
        case .news: "뉴스"
        case .json: "JSON 미리보기"
        }
    }
    var icon: String {
        switch self {
        case .source: "square.stack.3d.up"
        case .apps: "apps.iphone"
        case .news: "newspaper"
        case .json: "curlybraces"
        }
    }
}

struct SourceEditor: View {
    @EnvironmentObject private var store: SourceStore
    var body: some View {
        Form {
            Section("기본 정보") {
                TextField("소스 이름 *", text: $store.source.name)
                TextField("부제목", text: $store.source.subtitle)
                TextField("설명", text: $store.source.sourceDescription, axis: .vertical).lineLimit(3...6)
            }
            Section("이미지 및 색상") {
                TextField("아이콘 URL", text: $store.source.iconURL).urlField()
                TextField("헤더 이미지 URL", text: $store.source.headerURL).urlField()
                TextField("테마 색상 (#RRGGBB)", text: $store.source.tintColor)
            }
            Section("링크") {
                TextField("웹사이트", text: $store.source.website).urlField()
                TextField("Patreon URL", text: $store.source.patreonURL).urlField()
                TextField("Fediverse 사용자 이름", text: $store.source.fediUsername)
            }
            Section {
                TextField("Bundle ID를 한 줄에 하나씩", text: Binding(
                    get: { store.source.featuredApps.joined(separator: ", ") },
                    set: { store.source.featuredApps = $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                ), axis: .vertical)
            } header: { Text("추천 앱") } footer: { Text("쉼표로 구분해 입력합니다. 최대 5개가 표시됩니다.") }
        }
        .navigationTitle("소스 설정")
    }
}

struct AppsScreen: View {
    @EnvironmentObject private var store: SourceStore
    var body: some View {
        List {
            ForEach(store.source.apps.indices, id: \.self) { index in
                NavigationLink {
                    AppEditor(app: $store.source.apps[index])
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.source.apps[index].name.isEmpty ? "새 앱" : store.source.apps[index].name).font(.headline)
                        Text(store.source.apps[index].bundleIdentifier.isEmpty ? "Bundle ID 입력 필요" : store.source.apps[index].bundleIdentifier)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { store.source.apps.remove(atOffsets: $0) }
            .onMove { store.source.apps.move(fromOffsets: $0, toOffset: $1) }
        }
        .overlay {
            if store.source.apps.isEmpty { ContentUnavailableView("앱이 없습니다", systemImage: "apps.iphone", description: Text("앱을 추가해 AltSource 목록을 만드세요.")) }
        }
        .navigationTitle("앱")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { EditButton() }
            ToolbarItem(placement: .topBarTrailing) {
                Button { store.source.apps.append(AltApp()) } label: { Image(systemName: "plus") }
            }
        }
    }
}

struct AppEditor: View {
    @Binding var app: AltApp
    private let categories = ["developer", "entertainment", "games", "lifestyle", "other", "photo-video", "social", "utilities"]
    var body: some View {
        Form {
            Section("기본 정보") {
                TextField("앱 이름 *", text: $app.name)
                TextField("Bundle ID *", text: $app.bundleIdentifier).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("개발자 이름 *", text: $app.developerName)
                TextField("Marketplace ID", text: $app.marketplaceID)
                TextField("부제목", text: $app.subtitle)
                TextField("설명", text: $app.localizedDescription, axis: .vertical).lineLimit(3...8)
                Picker("카테고리", selection: $app.category) {
                    ForEach(categories, id: \.self) { Text($0).tag($0) }
                }
            }
            Section("이미지 및 색상") {
                TextField("아이콘 URL *", text: $app.iconURL).urlField()
                TextField("테마 색상 (#RRGGBB)", text: $app.tintColor)
                NavigationLink("스크린샷 (\(app.screenshots.iphone.count + app.screenshots.ipad.count))") {
                    ScreenshotsEditor(screenshots: $app.screenshots)
                }
            }
            Section("버전 · 첫 항목이 최신 버전") {
                ForEach(app.versions.indices, id: \.self) { index in
                    NavigationLink(app.versions[index].version.isEmpty ? "새 버전" : app.versions[index].version) {
                        VersionEditor(version: $app.versions[index])
                    }
                }
                .onDelete { app.versions.remove(atOffsets: $0) }
                .onMove { app.versions.move(fromOffsets: $0, toOffset: $1) }
                Button { app.versions.insert(AltVersion(), at: 0) } label: { Label("버전 추가", systemImage: "plus") }
            }
            Section("권한") {
                NavigationLink("Entitlements 및 개인정보 권한") { PermissionsEditor(permissions: $app.appPermissions) }
            }
            Section("Patreon 전용 앱") {
                TextField("최소 후원 금액", text: $app.patreon.pledge).keyboardType(.decimalPad)
                TextField("통화 코드 (예: USD)", text: $app.patreon.currency).textInputAutocapitalization(.characters)
                TextField("Benefit ID", text: $app.patreon.benefit)
                TextField("Tier ID (쉼표로 구분)", text: Binding(
                    get: { app.patreon.tiers.joined(separator: ", ") },
                    set: { app.patreon.tiers = $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } }
                ))
            }
        }
        .navigationTitle(app.name.isEmpty ? "새 앱" : app.name)
        .toolbar { EditButton() }
    }
}

struct VersionEditor: View {
    @Binding var version: AltVersion
    var body: some View {
        Form {
            Section("배포 파일") {
                TextField("IPA / ADP 다운로드 URL *", text: $version.downloadURL).urlField()
                TextField("파일 크기 (바이트) *", text: Binding(
                    get: { version.size == 0 ? "" : String(version.size) },
                    set: { version.size = Int($0) ?? 0 }
                )).keyboardType(.numberPad)
            }
            Section("버전 정보") {
                TextField("버전 번호 *", text: $version.version)
                TextField("빌드 번호", text: $version.buildVersion)
                TextField("표시 버전", text: $version.marketingVersion)
                TextField("출시일 (YYYY-MM-DD) *", text: $version.date)
                TextField("변경 사항", text: $version.localizedDescription, axis: .vertical).lineLimit(3...8)
                TextField("최소 iOS 버전", text: $version.minOSVersion)
                TextField("최대 iOS 버전", text: $version.maxOSVersion)
            }
            Section("ADP 파일별 URL") {
                TextField("파일명=URL 형식, 한 줄에 하나씩", text: Binding(
                    get: { version.assetURLs.keys.sorted().map { "\($0)=\(version.assetURLs[$0] ?? "")" }.joined(separator: "\n") },
                    set: { version.assetURLs = parsePairs($0) }
                ), axis: .vertical).lineLimit(2...6)
            }
        }
        .navigationTitle("버전 편집")
    }
}

struct ScreenshotsEditor: View {
    @Binding var screenshots: AppScreenshots
    var body: some View {
        Form {
            screenshotSection("iPhone", items: $screenshots.iphone)
            screenshotSection("iPad", items: $screenshots.ipad)
        }
        .navigationTitle("스크린샷")
    }
    private func screenshotSection(_ title: String, items: Binding<[Screenshot]>) -> some View {
        Section(title) {
            ForEach(items.wrappedValue.indices, id: \.self) { index in
                VStack(alignment: .leading) {
                    TextField("이미지 URL", text: items[index].imageURL).urlField()
                    HStack {
                        TextField("너비", text: items[index].width).keyboardType(.numberPad)
                        TextField("높이", text: items[index].height).keyboardType(.numberPad)
                    }
                }
            }
            .onDelete { items.wrappedValue.remove(atOffsets: $0) }
            Button { items.wrappedValue.append(Screenshot()) } label: { Label("추가", systemImage: "plus") }
        }
    }
}

struct PermissionsEditor: View {
    @Binding var permissions: AppPermissions
    var body: some View {
        Form {
            Section("Entitlements") {
                TextField("한 줄에 하나씩", text: Binding(
                    get: { permissions.entitlements.joined(separator: "\n") },
                    set: { permissions.entitlements = $0.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                ), axis: .vertical).lineLimit(4...10)
            }
            Section("Privacy UsageDescription") {
                TextField("키=설명 형식, 한 줄에 하나씩", text: Binding(
                    get: { permissions.privacy.keys.sorted().map { "\($0)=\(permissions.privacy[$0] ?? "")" }.joined(separator: "\n") },
                    set: { permissions.privacy = parsePairs($0) }
                ), axis: .vertical).lineLimit(4...10)
            }
        }
        .navigationTitle("권한")
    }
}

struct NewsScreen: View {
    @EnvironmentObject private var store: SourceStore
    var body: some View {
        List {
            ForEach(store.source.news.indices, id: \.self) { index in
                NavigationLink {
                    NewsEditor(news: $store.source.news[index])
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.source.news[index].title.isEmpty ? "새 뉴스" : store.source.news[index].title).font(.headline)
                        Text(store.source.news[index].date).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { store.source.news.remove(atOffsets: $0) }
        }
        .overlay {
            if store.source.news.isEmpty { ContentUnavailableView("뉴스가 없습니다", systemImage: "newspaper", description: Text("공지나 업데이트 소식을 추가하세요.")) }
        }
        .navigationTitle("뉴스")
        .toolbar { Button { store.source.news.append(AltNews()) } label: { Image(systemName: "plus") } }
    }
}

struct NewsEditor: View {
    @Binding var news: AltNews
    var body: some View {
        Form {
            Section("뉴스 정보") {
                TextField("제목 *", text: $news.title)
                TextField("고유 식별자 *", text: $news.identifier).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("한 줄 요약 *", text: $news.caption, axis: .vertical).lineLimit(2...4)
                TextField("게시일 (YYYY-MM-DD) *", text: $news.date)
                Toggle("알림 보내기", isOn: $news.notify)
            }
            Section("표시 및 링크") {
                TextField("이미지 URL", text: $news.imageURL).urlField()
                TextField("테마 색상 (#RRGGBB)", text: $news.tintColor)
                TextField("열기 URL", text: $news.url).urlField()
                TextField("관련 앱 Bundle ID", text: $news.appID)
            }
        }
        .navigationTitle(news.title.isEmpty ? "새 뉴스" : news.title)
    }
}

struct JSONScreen: View {
    @EnvironmentObject private var store: SourceStore
    let importAction: () -> Void
    let exportAction: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Button(action: importAction) { Label("가져오기", systemImage: "square.and.arrow.down") }
                        .buttonStyle(.bordered)
                    Button(action: exportAction) { Label("JSON 저장", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.borderedProminent)
                }
                if store.issues.isEmpty {
                    Label("필수 항목 검사를 통과했습니다", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("확인할 항목 \(store.issues.count)개", systemImage: "exclamationmark.triangle.fill").font(.headline)
                        ForEach(store.issues, id: \.self) { Text("• \($0)").font(.footnote) }
                    }
                    .foregroundStyle(.orange)
                }
                Text(store.jsonText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            }
            .padding()
        }
        .navigationTitle("JSON 미리보기")
    }
}

private func parsePairs(_ value: String) -> [String: String] {
    var result: [String: String] = [:]
    for line in value.components(separatedBy: .newlines) {
        guard let split = line.firstIndex(of: "=") else { continue }
        let key = String(line[..<split]).trimmingCharacters(in: .whitespaces)
        let text = String(line[line.index(after: split)...]).trimmingCharacters(in: .whitespaces)
        if !key.isEmpty && !text.isEmpty { result[key] = text }
    }
    return result
}

private extension View {
    func urlField() -> some View { textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled() }
}

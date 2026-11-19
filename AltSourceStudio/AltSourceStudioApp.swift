import SwiftUI
import PhotosUI
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
    @State private var importStartedAt: Date?
    @State private var exporting = false
    @State private var exportDocument: JSONFile?
    @State private var showWelcome = true
    @State private var confirmingNewProject = false
    @State private var selectedSection: EditorSection? = .source
    @State private var selectedTab: EditorSection = .source
    @State private var splitVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        Group {
            if showWelcome {
                WelcomeScreen(
                    hasDraft: store.hasSavedDraft,
                    importAction: { importing = true },
                    newProjectAction: {
                        if store.hasSavedDraft {
                            confirmingNewProject = true
                        } else {
                            store.newProject()
                            showWelcome = false
                        }
                    },
                    continueAction: { showWelcome = false }
                )
            } else if UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular {
                iPadLayout
            } else {
                compactLayout
            }
        }
        .sheet(isPresented: $importing) {
            JSONImportPicker(
                onPick: { url in
                    importing = false
                    beginImport(url)
                },
                onCancel: { importing = false }
            )
        }
        .overlay {
            if let started = importStartedAt {
                ZStack {
                    Color.black.opacity(0.25).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large)
                        Text("JSON 불러오는 중…").font(.headline)
                        TimelineView(.periodic(from: started, by: 0.1)) { context in
                            Text(String(format: "경과 %.1f초", max(0, context.date.timeIntervalSince(started))))
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                }
                .zIndex(1)
            }
        }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json,
                      defaultFilename: "AltSource.json") { result in
            if case .failure(let error) = result { store.message = error.localizedDescription }
        }
        .alert("AltSource Studio", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            Button("확인", role: .cancel) { store.message = nil }
        } message: { Text(store.message ?? "") }
        .confirmationDialog("현재 작업을 지우고 새 프로젝트를 만들까요?", isPresented: $confirmingNewProject) {
            Button("새 프로젝트 만들기", role: .destructive) {
                store.newProject()
                showWelcome = false
                selectedTab = .source
                selectedSection = .source
            }
        }
    }

    private var compactLayout: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                SourceEditor(viewCodeAction: { selectedTab = .json }, addAppAction: {
                    store.source.apps.append(AltApp())
                    selectedTab = .apps
                })
            }
                .tabItem { Label("소스", systemImage: "square.stack.3d.up") }
                .tag(EditorSection.source)
            NavigationStack { AppsScreen() }
                .tabItem { Label("앱", systemImage: "apps.iphone") }
                .tag(EditorSection.apps)
            NavigationStack { NewsScreen(viewCodeAction: { selectedTab = .json }) }
                .tabItem { Label("뉴스", systemImage: "newspaper") }
                .tag(EditorSection.news)
            NavigationStack { projectScreen }
                .tabItem { Label("Project", systemImage: "hammer.fill") }
                .tag(EditorSection.project)
            NavigationStack { jsonScreen }
                .tabItem { Label("JSON", systemImage: "curlybraces") }
                .tag(EditorSection.json)
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
                case .source: SourceEditor(viewCodeAction: { selectedSection = .json }, addAppAction: {
                    store.source.apps.append(AltApp())
                    selectedSection = .apps
                })
                case .apps: AppsScreen()
                case .news: NewsScreen(viewCodeAction: { selectedSection = .json })
                case .project: projectScreen
                case .json: jsonScreen
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var jsonScreen: some View {
        JSONScreen(importAction: { importing = true }, exportAction: beginExport)
    }

    private var projectScreen: some View {
        ProjectScreen(
            newAction: {
                if store.hasSavedDraft { confirmingNewProject = true }
                else { store.newProject(); selectedTab = .source; selectedSection = .source }
            },
            importAction: { importing = true },
            exportAction: beginExport,
            viewCodeAction: { selectedTab = .json; selectedSection = .json }
        )
    }

    private func beginExport() {
        exportDocument = JSONFile(data: store.jsonData())
        exporting = true
    }

    private func beginImport(_ url: URL) {
        let started = Date()
        importStartedAt = started
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<(Data, AltSource), Error> = Result {
                guard url.pathExtension.lowercased() == "json" else { throw JSONImportError.invalidExtension }
                let granted = url.startAccessingSecurityScopedResource()
                defer { if granted { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                return (data, try SourceStore.decodeJSON(data))
            }
            DispatchQueue.main.async {
                let remaining = max(0, 0.5 - Date().timeIntervalSince(started))
                DispatchQueue.main.asyncAfter(deadline: .now() + remaining) {
                    importStartedAt = nil
                    switch result {
                    case .success(let (data, source)):
                        store.applyImportedJSON(source, data: data)
                        showWelcome = false
                    case .failure(let error):
                        store.message = "JSON 파일을 불러오지 못했습니다: \(error.localizedDescription)"
                    }
                }
            }
        }
    }
}

private enum JSONImportError: LocalizedError {
    case invalidExtension
    var errorDescription: String? { "확장자가 .json인 파일만 선택할 수 있습니다." }
}

struct JSONImportPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onCancel: () -> Void
        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { onCancel(); return }
            onPick(url)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onCancel() }
    }
}

struct WelcomeScreen: View {
    let hasDraft: Bool
    let importAction: () -> Void
    let newProjectAction: () -> Void
    let continueAction: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack {
                    Spacer(minLength: 24)
                    VStack(spacing: 24) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 25)
                                .fill(LinearGradient(colors: [.indigo, .purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing))
                            Text("{ }")
                                .font(.system(size: 40, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 86, height: 86)
                        .accessibilityHidden(true)

                        Text("Welcome to AltSource Studio")
                            .font(.system(size: UIDevice.current.userInterfaceIdiom == .pad ? 34 : 28,
                                          weight: .bold, design: .rounded))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("AltStore용 소스 JSON을 만들고 관리하세요. 앱과 뉴스 정보를 입력한 뒤 JSON 파일로 저장할 수 있습니다.")
                            .font(.body)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 22) {
                            feature("rectangle.split.2x1", "편리한 편집", "소스, 앱, 버전과 뉴스를 한곳에서 관리합니다.")
                            feature("arrow.down.doc", "기존 JSON 가져오기", "파일 앱에서 AltSource JSON을 선택해 계속 편집합니다.")
                            feature("ipad.and.iphone", "iPhone·iPad 지원", "화면 크기에 맞는 편집 화면으로 작업합니다.")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 10)

                        Button(action: importAction) {
                            Text("JSON 가져오기")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)

                        Button("새 프로젝트", action: newProjectAction)
                            .font(.headline)

                        if hasDraft {
                            Button("이전 작업 계속하기", action: continueAction)
                                .font(.subheadline)
                        }
                    }
                    .padding(28)
                    .frame(maxWidth: 650)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 26))
                    Spacer(minLength: 24)
                }
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                .padding(.horizontal, 18)
            }
        }
        .background(Color(uiColor: .systemBackground))
    }

    private func feature(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private enum EditorSection: String, CaseIterable, Identifiable {
    case source, apps, news, project, json
    var id: Self { self }
    var title: String {
        switch self {
        case .source: "소스 설정"
        case .apps: "앱"
        case .news: "뉴스"
        case .project: "Project"
        case .json: "JSON 미리보기"
        }
    }
    var icon: String {
        switch self {
        case .source: "square.stack.3d.up"
        case .apps: "apps.iphone"
        case .news: "newspaper"
        case .project: "hammer.fill"
        case .json: "curlybraces"
        }
    }
}

struct SourceEditor: View {
    @EnvironmentObject private var store: SourceStore
    let viewCodeAction: () -> Void
    let addAppAction: () -> Void
    @State private var searchText = ""
    @State private var rowFrames: [String: CGRect] = [:]
    @State private var dragFrames: [String: CGRect] = [:]
    @State private var dragSlotIndices: [String: Int] = [:]
    @State private var handleDragID: String?
    @State private var dragFingerY: CGFloat = 0
    @State private var dragTouchOffset: CGFloat = 0

    private var visibleApps: [AltApp] {
        let apps = store.source.apps.filter { app in
            searchText.isEmpty || app.name.localizedCaseInsensitiveContains(searchText)
                || app.bundleIdentifier.localizedCaseInsensitiveContains(searchText)
        }
        let selected = store.source.featuredApps.compactMap { id in apps.first { $0.bundleIdentifier == id } }
        return selected + apps.filter { !store.source.featuredApps.contains($0.bundleIdentifier) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack {
                    Spacer()
                    Button(action: viewCodeAction) { Label("소스코드 보기", systemImage: "chevron.left.forwardslash.chevron.right") }
                        .font(.headline)
                }
                Text("소스")
                    .font(.system(size: 34, weight: .bold))
                    .padding(.bottom, 8)

                SourceImageField(title: "헤더 이미지", url: $store.source.headerURL, isHeader: true)
                SourceImageField(title: "아이콘", url: $store.source.iconURL, isHeader: false)

                SourceTextField(title: "틴트 컬러", text: $store.source.tintColor) {
                    ColorPicker("틴트 컬러", selection: Binding(
                        get: { sourceTintColor(store.source.tintColor) },
                        set: { store.source.tintColor = sourceHexColor($0) }
                    ), supportsOpacity: false)
                    .labelsHidden()
                }
                SourceTextField(title: "소스 이름", text: $store.source.name)
                SourceTextField(title: "소스 부제목 (선택 사항)", text: $store.source.subtitle)
                SourceTextField(title: "소스 설명 (선택 사항)", text: $store.source.sourceDescription, multiline: true)
                SourceTextField(title: "웹사이트 (선택 사항)", text: $store.source.website, isURL: true)
                SourceTextField(title: "Patreon URL (선택 사항)", text: $store.source.patreonURL, isURL: true)
                Text("웹사이트와 Patreon URL은 NightFox JSON 변환 규칙에 따라 내보내기에서 제외됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, -18)

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("대표 앱")
                        Spacer()
                        Button(action: addAppAction) { Label("추가", systemImage: "plus") }
                            .font(.headline)
                    }
                    featuredAppsPanel
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: 760)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemBackground))
        .coordinateSpace(name: "featuredReorder")
        .onPreferenceChange(ReorderRowFrames.self) { rowFrames = $0 }
        .toolbar(.hidden, for: .navigationBar)
        .keyboardDismissButton()
    }

    private var featuredAppsPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("검색", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .padding(12)
            .background(.white, in: RoundedRectangle(cornerRadius: 12))
            .padding(12)

            if store.source.apps.isEmpty {
                Text("앱을 추가하면 이곳에서 추천 앱을 선택할 수 있습니다.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            } else if visibleApps.isEmpty {
                Text("검색 결과가 없습니다.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            } else {
                ForEach(visibleApps, id: \.editorID) { app in
                    featuredRow(app)
                }
            }
        }
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private func featuredRow(_ app: AltApp) -> some View {
        let selected = store.source.featuredApps.contains(app.bundleIdentifier)
        if selected {
            featuredRowContent(app, selected: true)
                .contentShape(Rectangle())
                .reorderFrame(id: "featured:\(app.bundleIdentifier)", in: "featuredReorder")
                .offset(y: featuredDragOffset(for: app.bundleIdentifier))
                .scaleEffect(handleDragID == app.bundleIdentifier ? 1.025 : 1)
                .shadow(color: .black.opacity(handleDragID == app.bundleIdentifier ? 0.2 : 0), radius: 10, y: 6)
                .zIndex(handleDragID == app.bundleIdentifier ? 1 : 0)
        } else {
            featuredRowContent(app, selected: false)
        }
    }

    private func featuredRowContent(_ app: AltApp, selected: Bool) -> some View {
        HStack(spacing: 12) {
            if selected {
                ImmediateReorderHandle(
                    coordinateSpace: "featuredReorder",
                    label: "누른 채로 끌어 대표 앱 순서 변경",
                    onChange: { y in updateFeaturedDrag(app.bundleIdentifier, y: y) },
                    onEnd: { y in endFeaturedDrag(app.bundleIdentifier, y: y) }
                )
            } else {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.gray)
                    .frame(width: 24, height: 44)
                    .accessibilityLabel("대표 앱을 선택하면 순서를 바꿀 수 있습니다")
            }
            if selected {
                featuredAppDetails(app, selected: true)
                    .contentShape(Rectangle())
                    .pressToReorder(in: "featuredReorder",
                                    onChange: { y in updateFeaturedDrag(app.bundleIdentifier, y: y) },
                                    onEnd: { y in endFeaturedDrag(app.bundleIdentifier, y: y) })
            } else {
                featuredAppDetails(app, selected: false)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func featuredAppDetails(_ app: AltApp, selected: Bool) -> some View {
        HStack(spacing: 12) {
            RemoteImage(url: app.iconURL, systemName: "app", localData: app.iconPreviewData)
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name.isEmpty ? "새 앱" : app.name).font(.body).lineLimit(1)
                Text(app.bundleIdentifier).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button { toggleFeatured(app.bundleIdentifier) } label: {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? .blue : .gray)
            }
            .accessibilityLabel(selected ? "추천 앱에서 제거" : "추천 앱으로 선택")
        }
    }

    private func toggleFeatured(_ id: String) {
        guard !id.isEmpty else { return }
        let validIDs = Set(store.source.apps.map(\.bundleIdentifier))
        store.source.featuredApps.removeAll { !validIDs.contains($0) }
        if let index = store.source.featuredApps.firstIndex(of: id) {
            store.source.featuredApps.remove(at: index)
        } else if store.source.featuredApps.count < 5 {
            store.source.featuredApps.append(id)
        } else {
            store.message = "추천 앱은 최대 5개까지 선택할 수 있습니다."
        }
    }

    private func moveFeatured(_ sourceID: String, to targetIndex: Int) {
        var order = store.source.featuredApps
        guard let sourceIndex = order.firstIndex(of: sourceID),
              order.indices.contains(targetIndex),
              sourceIndex != targetIndex else { return }
        order.remove(at: sourceIndex)
        order.insert(sourceID, at: targetIndex)
        withAnimation(.interactiveSpring(response: 0.26, dampingFraction: 0.85)) { store.source.featuredApps = order }
    }

    private func updateFeaturedDrag(_ id: String, y: CGFloat) {
        if handleDragID == nil {
            dragFrames = rowFrames
            guard let frame = dragFrames["featured:\(id)"] else { return }
            dragSlotIndices = Dictionary(uniqueKeysWithValues: store.source.featuredApps.enumerated().map { ($0.element, $0.offset) })
            dragTouchOffset = y - frame.midY
            handleDragID = id
        }
        guard handleDragID == id else { return }
        dragFingerY = y
        let center = y - dragTouchOffset
        let slots = dragFrames.filter { $0.key.hasPrefix("featured:") }.sorted { $0.value.midY < $1.value.midY }
        if let target = slots.enumerated().min(by: {
            abs($0.element.value.midY - center) < abs($1.element.value.midY - center)
        })?.offset,
           let slotIndex = dragSlotIndices[String(slots[target].key.dropFirst(9))] {
            moveFeatured(id, to: slotIndex)
        }
    }

    private func featuredDragOffset(for id: String) -> CGFloat {
        guard handleDragID == id, let frame = rowFrames["featured:\(id)"] else { return 0 }
        return dragFingerY - dragTouchOffset - frame.midY
    }

    private func endFeaturedDrag(_ id: String, y: CGFloat) {
        updateFeaturedDrag(id, y: y)
        guard handleDragID == id else { return }
        withAnimation(.interactiveSpring(response: 0.28, dampingFraction: 0.86)) { handleDragID = nil }
        dragFrames = [:]
        dragSlotIndices = [:]
    }
}

struct SourceImageField: View {
    let title: String
    @Binding var url: String
    let isHeader: Bool
    var importedPreview: Data? = nil
    var clearImportedPreview: (() -> Void)? = nil
    @State private var selectedImage: PhotosPickerItem?
    @State private var localPreview: Data?
    @State private var exportingIcon = false

    private var previewData: Data? { localPreview ?? importedPreview }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 14) {
                Group {
                    if url.isEmpty, let previewData, let image = UIImage(data: previewData) {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        RemoteImage(url: url, systemName: "photo", localData: previewData)
                    }
                }
                .frame(width: isHeader ? 96 : 70, height: isHeader ? 76 : 70)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.subheadline)
                    TextField("이미지 URL", text: $url)
                        .urlField()
                        .padding(.horizontal, 12)
                        .frame(height: 38)
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                    HStack {
                        PhotosPicker(selection: $selectedImage, matching: .images) {
                            Text("이미지 선택")
                        }
                        Spacer()
                        if !url.isEmpty || previewData != nil {
                            Button("삭제", role: .destructive) {
                                url = ""
                                localPreview = nil
                                selectedImage = nil
                                clearImportedPreview?()
                            }
                            .foregroundStyle(.red)
                        }
                    }
                    .font(.subheadline)
                }
            }
            if previewData != nil {
                if importedPreview != nil {
                    Button("추출한 아이콘 저장") { exportingIcon = true }
                        .font(.subheadline)
                }
                Text("아이콘 파일은 미리보기용입니다. JSON에는 공개 이미지 URL이 필요합니다.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .fileExporter(isPresented: $exportingIcon,
                      document: importedPreview.map(PNGFile.init),
                      contentType: .png,
                      defaultFilename: "AppIcon") { _ in }
        .onChange(of: selectedImage) { _, item in
            Task { localPreview = try? await item?.loadTransferable(type: Data.self) }
        }
        .onChange(of: url) { _, _ in localPreview = nil }
    }
}

struct RemoteImage: View {
    let url: String
    let systemName: String
    var localData: Data? = nil
    var body: some View {
        Group {
            if url.isEmpty, let localData, let image = UIImage(data: localData) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                AsyncImage(url: URL(string: url)) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Rectangle().fill(Color(uiColor: .secondarySystemBackground))
                            .overlay(Image(systemName: systemName).foregroundStyle(.secondary))
                    }
                }
            }
        }
        .clipped()
    }
}

struct SourceTextField<Accessory: View>: View {
    let title: String
    @Binding var text: String
    var multiline = false
    var isURL = false
    @ViewBuilder var accessory: () -> Accessory

    init(title: String, text: Binding<String>, multiline: Bool = false, isURL: Bool = false,
         @ViewBuilder accessory: @escaping () -> Accessory) {
        self.title = title
        self._text = text
        self.multiline = multiline
        self.isURL = isURL
        self.accessory = accessory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline)
            HStack(alignment: multiline ? .top : .center) {
                Group {
                    if multiline {
                        TextField("", text: $text, axis: .vertical).lineLimit(5...8)
                    } else {
                        TextField("", text: $text)
                            .textInputAutocapitalization(isURL ? .never : .sentences)
                            .autocorrectionDisabled(isURL)
                            .keyboardType(isURL ? .URL : .default)
                    }
                }
                .frame(maxWidth: .infinity)
                accessory()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, multiline ? 12 : 0)
            .frame(minHeight: multiline ? 92 : 38)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

extension SourceTextField where Accessory == EmptyView {
    init(title: String, text: Binding<String>, multiline: Bool = false, isURL: Bool = false) {
        self.init(title: title, text: text, multiline: multiline, isURL: isURL) { EmptyView() }
    }
}

func sourceTintColor(_ hex: String) -> Color {
    let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard value.count == 6, let number = Int(value, radix: 16) else { return .gray }
    return Color(red: Double((number >> 16) & 0xff) / 255,
                 green: Double((number >> 8) & 0xff) / 255,
                 blue: Double(number & 0xff) / 255)
}

func sourceHexColor(_ color: Color) -> String {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    return String(format: "#%02x%02x%02x", Int(red * 255), Int(green * 255), Int(blue * 255))
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
        .keyboardDismissButton()
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
        .keyboardDismissButton()
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
            Section("앱 권한 설정") {
                TextField("한 줄에 하나씩", text: Binding(
                    get: { permissions.entitlements.joined(separator: "\n") },
                    set: { permissions.entitlements = $0.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                ), axis: .vertical).lineLimit(4...10)
            }
            Section("개인정보 사용 설명") {
                TextField("키=설명 형식, 한 줄에 하나씩", text: Binding(
                    get: { permissions.privacy.keys.sorted().map { "\($0)=\(permissions.privacy[$0] ?? "")" }.joined(separator: "\n") },
                    set: { permissions.privacy = parsePairs($0) }
                ), axis: .vertical).lineLimit(4...10)
            }
        }
        .navigationTitle("권한")
        .keyboardDismissButton()
    }
}

extension View {
    func keyboardDismissButton() -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                } label: {
                    Label("키보드 내리기", systemImage: "keyboard.chevron.compact.down")
                }
                .accessibilityLabel("키보드 내리기")
            }
        }
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

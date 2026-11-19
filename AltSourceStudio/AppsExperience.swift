import SwiftUI
import UniformTypeIdentifiers

struct ReorderRowFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

struct ImmediateReorderHandle: View {
    let coordinateSpace: String
    let label: String
    let onChange: (CGFloat) -> Void
    let onEnd: (CGFloat) -> Void

    var body: some View {
        Image(systemName: "line.3.horizontal")
            .foregroundStyle(.blue)
            .frame(width: 24, height: 44)
            .contentShape(Rectangle())
            .accessibilityLabel(label)
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(coordinateSpace))
                    .onChanged { value in onChange(value.location.y) }
                    .onEnded { value in onEnd(value.location.y) }
            )
    }
}

extension View {
    func reorderFrame(id: String, in coordinateSpace: String) -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(key: ReorderRowFrames.self,
                                       value: [id: geometry.frame(in: .named(coordinateSpace))])
            }
        }
    }

    func pressToReorder(in coordinateSpace: String,
                        onChange: @escaping (CGFloat) -> Void,
                        onEnd: @escaping (CGFloat) -> Void) -> some View {
        simultaneousGesture(
            LongPressGesture(minimumDuration: 0.3)
                .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(coordinateSpace)))
                .onChanged { phase in
                    if case .second(true, let drag?) = phase { onChange(drag.location.y) }
                }
                .onEnded { phase in
                    if case .second(true, let drag?) = phase { onEnd(drag.location.y) }
                }
        )
    }
}

struct AppsScreen: View {
    @EnvironmentObject private var store: SourceStore
    @State private var search = ""
    @State private var editing = false
    @State private var openNewApp = false
    @State private var rowFrames: [String: CGRect] = [:]
    @State private var dragFrames: [String: CGRect] = [:]
    @State private var dragSlotIndices: [UUID: Int] = [:]
    @State private var draggedAppID: UUID?
    @State private var dragFingerY: CGFloat = 0
    @State private var dragTouchOffset: CGFloat = 0

    private var visibleApps: [AltApp] {
        store.source.apps.filter { app in
            return search.isEmpty || app.name.localizedCaseInsensitiveContains(search)
                || app.bundleIdentifier.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Apps").font(.system(size: 34, weight: .bold)).padding(.top, 14)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search", text: $search)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                .padding(12)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                Divider()
                HStack {
                    Text("Total \(store.source.apps.count)").font(.headline)
                    Spacer()
                    Button {
                        store.source.apps.append(AltApp())
                        openNewApp = true
                    } label: {
                        Image(systemName: "plus.circle")
                            .resizable().scaledToFit()
                            .frame(width: 26, height: 26)
                            .frame(width: 36, height: 36)
                    }
                    .accessibilityLabel("앱 추가")
                    Button { editing.toggle() } label: {
                        Image(systemName: editing ? "checkmark.circle" : "square.and.pencil")
                            .resizable().scaledToFit()
                            .frame(width: 26, height: 26)
                            .frame(width: 36, height: 36)
                    }
                    .accessibilityLabel(editing ? "편집 완료" : "앱 목록 편집")
                }

                if store.source.apps.isEmpty {
                    ContentUnavailableView("앱이 없습니다", systemImage: "apps.iphone", description: Text("앱을 추가해 주세요."))
                } else if visibleApps.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(visibleApps, id: \.editorID) { app in
                            if let index = store.source.apps.firstIndex(where: { $0.editorID == app.editorID }) {
                            HStack(spacing: 7) {
                                if editing {
                                    Button(role: .destructive) { removeApp(index) } label: {
                                        Image(systemName: "minus.circle.fill")
                                    }
                                    ImmediateReorderHandle(
                                        coordinateSpace: "appsReorder",
                                        label: "누른 채로 끌어 앱 순서 변경",
                                        onChange: { y in updateDrag(app.editorID, y: y) },
                                        onEnd: { y in endDrag(app.editorID, y: y) }
                                    )
                                }
                                NavigationLink {
                                    AppEditor(app: $store.source.apps[index])
                                } label: {
                                    appCard(app)
                                }
                                .buttonStyle(.plain)
                                .pressToReorder(in: "appsReorder",
                                                onChange: { y in updateDrag(app.editorID, y: y) },
                                                onEnd: { y in endDrag(app.editorID, y: y) })
                            }
                            .contentShape(Rectangle())
                            .reorderFrame(id: "app:\(app.editorID.uuidString)", in: "appsReorder")
                            .offset(y: dragOffset(for: app.editorID))
                            .scaleEffect(draggedAppID == app.editorID ? 1.025 : 1)
                            .shadow(color: .black.opacity(draggedAppID == app.editorID ? 0.22 : 0), radius: 12, y: 8)
                            .zIndex(draggedAppID == app.editorID ? 1 : 0)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 760)
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemBackground))
        .coordinateSpace(name: "appsReorder")
        .onPreferenceChange(ReorderRowFrames.self) { rowFrames = $0 }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(isPresented: $openNewApp) {
            if let index = store.source.apps.indices.last {
                AppEditor(app: $store.source.apps[index])
            }
        }
        .keyboardDismissButton()
    }

    private func appCard(_ app: AltApp) -> some View {
        let tint = sourceTintColor(app.tintColor)
        return HStack(spacing: 14) {
            RemoteImage(url: app.iconURL, systemName: "app")
                .frame(width: 64, height: 64)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name.isEmpty ? "새 앱" : app.name)
                    .font(.headline).foregroundStyle(.primary).lineLimit(2)
                Text(app.bundleIdentifier.isEmpty ? "Bundle ID 입력 필요" : app.bundleIdentifier)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Text("EDIT")
                .font(.caption.weight(.bold)).foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(tint, in: Capsule())
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.23), in: RoundedRectangle(cornerRadius: 18))
    }

    private func removeApp(_ index: Int) {
        let id = store.source.apps[index].bundleIdentifier
        store.source.apps.remove(at: index)
        store.source.featuredApps.removeAll { $0 == id }
    }

    private func moveApp(_ id: UUID, to targetIndex: Int) {
        var apps = store.source.apps
        guard let sourceIndex = apps.firstIndex(where: { $0.editorID == id }),
              apps.indices.contains(targetIndex),
              sourceIndex != targetIndex else { return }
        let moved = apps.remove(at: sourceIndex)
        apps.insert(moved, at: targetIndex)
        withAnimation(.interactiveSpring(response: 0.26, dampingFraction: 0.85)) { store.source.apps = apps }
    }

    private func updateDrag(_ id: UUID, y: CGFloat) {
        let key = "app:\(id.uuidString)"
        if draggedAppID == nil {
            dragFrames = rowFrames
            guard let frame = dragFrames[key] else { return }
            dragSlotIndices = Dictionary(uniqueKeysWithValues: store.source.apps.enumerated().map { ($0.element.editorID, $0.offset) })
            dragTouchOffset = y - frame.midY
            draggedAppID = id
        }
        guard draggedAppID == id else { return }
        dragFingerY = y
        let center = y - dragTouchOffset
        let slots = dragFrames.filter { $0.key.hasPrefix("app:") }.sorted { $0.value.midY < $1.value.midY }
        guard let target = slots.enumerated().min(by: {
            abs($0.element.value.midY - center) < abs($1.element.value.midY - center)
        })?.offset else { return }
        let targetID = UUID(uuidString: String(slots[target].key.dropFirst(4)))
        if let targetID, let slotIndex = dragSlotIndices[targetID] {
            moveApp(id, to: slotIndex)
        }
    }

    private func dragOffset(for id: UUID) -> CGFloat {
        guard draggedAppID == id, let frame = rowFrames["app:\(id.uuidString)"] else { return 0 }
        return dragFingerY - dragTouchOffset - frame.midY
    }

    private func endDrag(_ id: UUID, y: CGFloat) {
        updateDrag(id, y: y)
        guard draggedAppID == id else { return }
        withAnimation(.interactiveSpring(response: 0.28, dampingFraction: 0.86)) { draggedAppID = nil }
        dragFrames = [:]
        dragSlotIndices = [:]
    }
}

private enum AppSheet: String, Identifiable {
    case addVersion, addPrivacy, addEntitlement
    var id: String { rawValue }
}

struct AppEditor: View {
    @EnvironmentObject private var store: SourceStore
    @Binding var app: AltApp
    @State private var sheet: AppSheet?
    @State private var versionDraft = AltVersion()
    @State private var versionSearch = ""
    @State private var showAllVersions = false
    @State private var showAllPrivacy = false
    @State private var editingVersions = false
    @State private var scanningFile = false
    @State private var selectedFileName: String?
    @State private var newPrivacyKey = ""
    @State private var newPrivacyValue = ""
    @State private var newEntitlement = ""
    private let categories = ["developer", "entertainment", "games", "lifestyle", "other", "photo-video", "social", "utilities"]

    private var matchingVersions: [Int] {
        app.versions.indices.filter { index in
            versionSearch.isEmpty || app.versions[index].version.localizedCaseInsensitiveContains(versionSearch)
                || app.versions[index].localizedDescription.localizedCaseInsensitiveContains(versionSearch)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                SourceImageField(title: "Icon", url: $app.iconURL, isHeader: false)
                AppInputField(title: "Name", text: $app.name)
                AppInputField(title: "Bundle identifier", text: $app.bundleIdentifier, identifier: true)
                AppInputField(title: "Marketplace ID (optional)", text: $app.marketplaceID)
                Text("Marketplace ID는 현재 JSON 내보내기 형식에서 제외됩니다.")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, -18)
                SourceTextField(title: "Tint color", text: $app.tintColor) {
                    ColorPicker("Tint color", selection: Binding(
                        get: { sourceTintColor(app.tintColor) },
                        set: { app.tintColor = sourceHexColor($0) }
                    ), supportsOpacity: false).labelsHidden()
                }
                AppInputField(title: "Developer name", text: $app.developerName)
                AppInputField(title: "Subtitle (optional)", text: $app.subtitle)
                AppInputField(title: "Description (optional)", text: $app.localizedDescription, multiline: true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Category (optional)").font(.subheadline)
                    Picker("Category", selection: $app.category) {
                        ForEach(categories, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .frame(height: 42)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                }
                screenshotsSection
                versionsSection
                privacySection
                entitlementsSection
            }
            .frame(maxWidth: 760)
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemBackground))
        .toolbar(.visible, for: .navigationBar)
        .navigationTitle("App editor")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) { editorToolbar }
        .sheet(item: $sheet) { selected in
            switch selected {
            case .addVersion:
                AddVersionSheet(version: $versionDraft, fileName: selectedFileName) {
                    app.versions.insert(versionDraft, at: 0)
                    sheet = nil
                }
            case .addPrivacy:
                addPrivacySheet
            case .addEntitlement:
                addEntitlementSheet
            }
        }
        .fileImporter(isPresented: $scanningFile, allowedContentTypes: [UTType(filenameExtension: "ipa") ?? .zip, UTType(filenameExtension: "adp") ?? .zip]) { result in
            scanSelectedFile(result)
        }
        .onChange(of: app.bundleIdentifier) { oldID, newID in
            if !oldID.isEmpty, let index = store.source.featuredApps.firstIndex(of: oldID) {
                if newID.isEmpty { store.source.featuredApps.remove(at: index) }
                else { store.source.featuredApps[index] = newID }
            }
        }
        .keyboardDismissButton()
    }

    private var editorToolbar: some View {
        HStack {
            Button { toggleFeatured() } label: {
                Image(systemName: store.source.featuredApps.contains(app.bundleIdentifier) ? "star.fill" : "star")
                    .foregroundStyle(.orange).font(.title2)
            }
            .accessibilityLabel("대표 앱 선택")
            Spacer()
            Button { scanningFile = true } label: { Label("Scan IPA / ADP", systemImage: "doc") }
                .font(.subheadline)
            Menu {
                Button("앱 복제", systemImage: "plus.square.on.square") {
                    var copy = app
                    copy.name += " copy"
                    copy.bundleIdentifier = ""
                    store.source.apps.append(copy)
                }
            } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel("더 보기")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(uiColor: .systemBackground))
    }

    private var screenshotsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Screenshots").font(.subheadline)
            VStack(spacing: 0) {
                screenshotRow("iPhone", count: app.screenshots.iphone.count)
                screenshotRow("iPad", count: app.screenshots.ipad.count)
            }
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func screenshotRow(_ title: String, count: Int) -> some View {
        NavigationLink {
            ScreenshotsEditor(screenshots: $app.screenshots)
        } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                Text("\(count)")
                    .font(.caption.weight(.bold)).foregroundStyle(.white)
                    .frame(minWidth: 23, minHeight: 23)
                    .background(sourceTintColor(app.tintColor), in: Circle())
                Image(systemName: "chevron.down").font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
        }
    }

    private var versionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Versions").font(.subheadline)
                Spacer()
                Menu {
                    Button("Add manually", systemImage: "pencil") {
                        versionDraft = AltVersion()
                        selectedFileName = nil
                        sheet = .addVersion
                    }
                    Button("Scan IPA / ADP file", systemImage: "doc") { scanningFile = true }
                } label: { Label("Add", systemImage: "plus") }
                Button { editingVersions.toggle() } label: {
                    Label(editingVersions ? "Done" : "Edit", systemImage: "square.and.pencil")
                }
            }
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search", text: $versionSearch).textInputAutocapitalization(.never)
                }
                .padding(11)
                .background(.white, in: RoundedRectangle(cornerRadius: 11))
                .padding(12)

                if app.versions.isEmpty {
                    Text("추가된 버전이 없습니다.").foregroundStyle(.secondary).padding(16)
                } else if matchingVersions.isEmpty {
                    Text("검색 결과가 없습니다.").foregroundStyle(.secondary).padding(16)
                } else {
                    ForEach(Array(matchingVersions.prefix(showAllVersions ? Int.max : 4)), id: \.self) { index in
                        versionRow(index)
                    }
                    if matchingVersions.count > 4 {
                        Button {
                            showAllVersions.toggle()
                        } label: {
                            Text(showAllVersions ? "Show less" : "Show all")
                            Text("\(matchingVersions.count)")
                                .font(.caption.weight(.bold)).foregroundStyle(.white)
                                .padding(5)
                                .background(sourceTintColor(app.tintColor), in: Circle())
                        }
                        .foregroundStyle(sourceTintColor(app.tintColor))
                        .padding(14)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func versionRow(_ index: Int) -> some View {
        let version = app.versions[index]
        return HStack(spacing: 10) {
            Circle().fill(.gray.opacity(0.45)).frame(width: 9, height: 9)
            NavigationLink {
                VersionEditor(version: $app.versions[index])
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(version.version.isEmpty ? "새 버전" : version.version)
                            .font(.caption.weight(.semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(sourceTintColor(app.tintColor), in: Capsule())
                        Spacer()
                        Text(appVersionDate(version.date)).font(.caption2).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(version.localizedDescription.isEmpty ? version.downloadURL : version.localizedDescription)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .buttonStyle(.plain)
            if editingVersions {
                Button(role: .destructive) { app.versions.remove(at: index) } label: {
                    Image(systemName: "minus.circle.fill")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var privacySection: some View {
        let entries = app.appPermissions.privacy.keys.sorted()
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Privacy").font(.subheadline)
                Spacer()
                Button {
                    newPrivacyKey = ""
                    newPrivacyValue = ""
                    sheet = .addPrivacy
                } label: { Label("Add", systemImage: "plus") }
                NavigationLink { PermissionsEditor(permissions: $app.appPermissions) } label: {
                    Label("Edit", systemImage: "square.and.pencil")
                }
            }
            VStack(spacing: 0) {
                if entries.isEmpty {
                    Text("No app privacy items")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                } else {
                    ForEach(Array(entries.prefix(showAllPrivacy ? Int.max : 4)), id: \.self) { key in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(key).font(.subheadline).foregroundStyle(.primary).lineLimit(1)
                            Text(app.appPermissions.privacy[key] ?? "")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                        if key != entries.last { Divider().padding(.leading, 14) }
                    }
                    if entries.count > 4 {
                        Button(showAllPrivacy ? "Show less" : "Show all \(entries.count)") {
                            showAllPrivacy.toggle()
                        }
                        .foregroundStyle(sourceTintColor(app.tintColor)).padding(14)
                    }
                }
            }
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var entitlementsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Entitlements").font(.subheadline)
                Spacer()
                Button { newEntitlement = ""; sheet = .addEntitlement } label: { Label("Add", systemImage: "plus") }
                NavigationLink { PermissionsEditor(permissions: $app.appPermissions) } label: {
                    Label("Edit", systemImage: "square.and.pencil")
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                if app.appPermissions.entitlements.isEmpty {
                    Text("No app entitlements items").foregroundStyle(.secondary)
                } else {
                    ForEach(app.appPermissions.entitlements, id: \.self) { item in
                        Text(item).font(.subheadline)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var addPrivacySheet: some View {
        NavigationStack {
            Form {
                TextField("권한 키", text: $newPrivacyKey).textInputAutocapitalization(.never)
                TextField("설명", text: $newPrivacyValue, axis: .vertical)
            }
            .navigationTitle("Privacy 추가")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { sheet = nil } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("추가") {
                        app.appPermissions.privacy[newPrivacyKey] = newPrivacyValue
                        sheet = nil
                    }
                    .disabled(newPrivacyKey.isEmpty)
                }
            }
            .keyboardDismissButton()
        }
    }

    private var addEntitlementSheet: some View {
        NavigationStack {
            Form { TextField("Entitlement", text: $newEntitlement).textInputAutocapitalization(.never) }
                .navigationTitle("Entitlement 추가")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("취소") { sheet = nil } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("추가") {
                            app.appPermissions.entitlements.append(newEntitlement)
                            sheet = nil
                        }
                        .disabled(newEntitlement.isEmpty)
                    }
                }
                .keyboardDismissButton()
        }
    }

    private func toggleFeatured() {
        let id = app.bundleIdentifier
        guard !id.isEmpty else { store.message = "Bundle ID를 먼저 입력하세요."; return }
        if let index = store.source.featuredApps.firstIndex(of: id) {
            store.source.featuredApps.remove(at: index)
        } else if store.source.featuredApps.count < 5 {
            store.source.featuredApps.append(id)
        } else {
            store.message = "대표 앱은 최대 5개까지 선택할 수 있습니다."
        }
    }

    private func scanSelectedFile(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let ext = url.pathExtension.lowercased()
            guard ext == "ipa" || ext == "adp" else {
                store.message = "IPA 또는 ADP 파일을 선택하세요."
                return
            }
            let granted = url.startAccessingSecurityScopedResource()
            defer { if granted { url.stopAccessingSecurityScopedResource() } }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            versionDraft = AltVersion()
            versionDraft.size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            selectedFileName = url.lastPathComponent
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { sheet = .addVersion }
        } catch {
            store.message = "파일을 열지 못했습니다: \(error.localizedDescription)"
        }
    }
}

private func appVersionDate(_ value: String) -> String {
    let components = String(value.prefix(10)).split(separator: "-")
    guard components.count == 3 else { return value }
    return "\(components[0])년 \(Int(components[1]) ?? 0)월 \(Int(components[2]) ?? 0)일"
}

struct AppInputField: View {
    let title: String
    @Binding var text: String
    var placeholder = ""
    var multiline = false
    var identifier = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline)
            HStack(alignment: multiline ? .top : .center, spacing: 8) {
                Group {
                    if multiline {
                        TextField(placeholder, text: $text, axis: .vertical).lineLimit(5...8)
                    } else {
                        TextField(placeholder, text: $text)
                            .textInputAutocapitalization(identifier ? .never : .sentences)
                            .autocorrectionDisabled(identifier)
                    }
                }
                .frame(maxWidth: .infinity)
                if !text.isEmpty {
                    Button { text = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("\(title) 지우기")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, multiline ? 12 : 0)
            .frame(minHeight: multiline ? 115 : 42)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

private struct AddVersionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var version: AltVersion
    let fileName: String?
    let addAction: () -> Void
    @State private var sizeText = ""
    @State private var sizeUnit = "MB"
    private let units = ["bytes", "KB", "MB", "GB"]

    private var canAdd: Bool {
        !version.downloadURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !version.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && version.size > 0
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let fileName {
                        Text("\(fileName)의 크기를 입력했습니다. 배포용 다운로드 URL과 버전 정보는 직접 입력해 주세요.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    AppInputField(title: "IPA / ADP download URL *", text: $version.downloadURL,
                                  placeholder: "https://site.com/someapp.ipa", identifier: true)
                    HStack(alignment: .bottom, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("IPA file size *").font(.subheadline)
                            TextField("0.0", text: $sizeText)
                                .keyboardType(.decimalPad)
                                .padding(.horizontal, 12)
                                .frame(height: 42)
                                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Unit").font(.subheadline)
                            Picker("Unit", selection: $sizeUnit) {
                                ForEach(units, id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden()
                            .padding(.horizontal, 8)
                            .frame(height: 42)
                            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                        }
                    }
                    AppInputField(title: "Version number *", text: $version.version, placeholder: "1.0.0")
                    AppInputField(title: "Build version (optional)", text: $version.buildVersion, placeholder: "123")
                    Text("Build version은 현재 JSON 내보내기 형식에서 제외됩니다.")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, -18)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Release date *").font(.subheadline)
                        DatePicker("Release date", selection: dateBinding, displayedComponents: [.date, .hourAndMinute])
                            .labelsHidden()
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 12)
                            .frame(height: 42)
                            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                    }
                    AppInputField(title: "Short description (optional)", text: $version.localizedDescription,
                                  placeholder: "Some changes", multiline: true)
                    AppInputField(title: "Min iOS (optional)", text: $version.minOSVersion, placeholder: "16.1")
                }
                .frame(maxWidth: 760)
                .padding(16)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Add App Version")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button(action: addAction) {
                    Text("Add").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 11)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canAdd)
                .padding(16)
                .background(Color(uiColor: .systemBackground))
            }
            .onAppear {
                if version.size > 0 { sizeText = String(format: "%.1f", Double(version.size) / 1_000_000) }
            }
            .onChange(of: sizeText) { _, _ in updateSize() }
            .onChange(of: sizeUnit) { _, _ in
                if version.size > 0 {
                    sizeText = String(format: "%.1f", Double(version.size) / sizeMultiplier)
                }
            }
            .keyboardDismissButton()
        }
    }

    private var dateBinding: Binding<Date> {
        Binding(get: {
            ISO8601DateFormatter().date(from: version.date) ?? Date()
        }, set: { date in
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = TimeZone(secondsFromGMT: 9 * 3600)
            formatter.formatOptions = [.withInternetDateTime]
            version.date = formatter.string(from: date)
        })
    }

    private func updateSize() {
        version.size = Int((Double(sizeText) ?? 0) * sizeMultiplier)
    }

    private var sizeMultiplier: Double {
        switch sizeUnit {
        case "KB": return 1_000
        case "MB": return 1_000_000
        case "GB": return 1_000_000_000
        default: return 1
        }
    }
}

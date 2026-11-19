import SwiftUI
import PhotosUI

struct NewsScreen: View {
    @EnvironmentObject private var store: SourceStore
    let viewCodeAction: () -> Void
    @State private var search = ""
    @State private var editing = false
    @State private var newEditorIndex: Int?
    @State private var showingNewEditor = false

    private var indices: [Int] {
        store.source.news.indices.filter { index in
            let item = store.source.news[index]
            let appName = store.source.apps.first { $0.bundleIdentifier == item.appID }?.name ?? ""
            return search.isEmpty || [item.title, item.caption, appName].contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("News").font(.title2.bold()).frame(maxWidth: .infinity).padding(.top, 10)
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search", text: $search)
                }
                .padding(14)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 15))
                Divider().padding(.top, 3)
                HStack {
                    Text("Total \(store.source.news.count)").font(.headline)
                    Spacer()
                    Button {
                        var item = AltNews()
                        item.identifier = "news_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10).lowercased()
                        item.tintColor = store.source.tintColor.isEmpty ? "#00b39e" : store.source.tintColor
                        store.source.news.append(item)
                        newEditorIndex = store.source.news.count - 1
                        showingNewEditor = true
                    } label: { Image(systemName: "plus.circle").font(.title3) }
                    .accessibilityLabel("뉴스 추가")
                    Button { editing.toggle() } label: {
                        Image(systemName: editing ? "checkmark.circle" : "square.and.pencil").font(.title3)
                    }
                    .accessibilityLabel(editing ? "편집 완료" : "뉴스 편집")
                }
                if indices.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "뉴스가 없습니다" : "검색 결과가 없습니다", systemImage: "newspaper")
                }
                ForEach(indices, id: \.self) { index in
                    HStack(spacing: 8) {
                        if editing {
                            Button(role: .destructive) { store.source.news.remove(at: index) } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                            }
                            .accessibilityLabel("뉴스 삭제")
                        }
                        NavigationLink {
                            editor(at: index)
                        } label: {
                            NewsCard(news: store.source.news[index], apps: store.source.apps)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
            .frame(maxWidth: 780)
            .frame(maxWidth: .infinity)
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showingNewEditor) {
            if let newEditorIndex { editor(at: newEditorIndex) }
        }
        .keyboardDismissButton()
    }

    @ViewBuilder private func editor(at index: Int) -> some View {
        if store.source.news.indices.contains(index) {
            NewsEditor(news: $store.source.news[index], apps: store.source.apps,
                       viewCodeAction: viewCodeAction,
                       deleteAction: {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    if store.source.news.indices.contains(index) { store.source.news.remove(at: index) }
                }
            })
        }
    }
}

private struct NewsCard: View {
    let news: AltNews
    let apps: [AltApp]
    private var app: AltApp? { apps.first { $0.bundleIdentifier == news.appID } }
    private var tint: Color { sourceTintColor(news.tintColor.isEmpty ? (app?.tintColor ?? "#00b39e") : news.tintColor) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    if news.notify { Image(systemName: "bell.fill") }
                    Text(newsDisplayDate(news.date)).font(.caption)
                }
                Text(news.title.isEmpty ? "New announcement" : news.title)
                    .font(.title3.bold()).lineLimit(2)
                if !news.caption.isEmpty { Text(news.caption).font(.subheadline).lineLimit(2) }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(tint)
            if let app {
                HStack(spacing: 12) {
                    RemoteImage(url: app.iconURL, systemName: "app.fill")
                        .frame(width: 54, height: 54).clipShape(RoundedRectangle(cornerRadius: 13))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name).font(.headline).foregroundStyle(.primary).lineLimit(1)
                        Text(app.bundleIdentifier).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(tint.opacity(0.22))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22))
    }
}

private struct NewsEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var news: AltNews
    let apps: [AltApp]
    let viewCodeAction: () -> Void
    let deleteAction: () -> Void
    @State private var choosingApp = false
    @State private var deleting = false

    private var dateBinding: Binding<Date> {
        Binding(get: { newsDate(news.date) }, set: { news.date = newsISODate($0) })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Spacer()
                    Button(action: viewCodeAction) { Label("View code", systemImage: "chevron.left.forwardslash.chevron.right") }
                    Divider().frame(height: 20)
                    Button(role: .destructive) { deleting = true } label: { Image(systemName: "trash") }
                        .accessibilityLabel("뉴스 삭제")
                }
                NewsPosterField(url: $news.imageURL)
                AppInputField(title: "Title", text: $news.title)
                AppInputField(title: "Identifier", text: $news.identifier, identifier: true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tint color").font(.subheadline)
                    HStack {
                        TextField("#00b39e", text: $news.tintColor)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        ColorPicker("Tint color", selection: Binding(
                            get: { sourceTintColor(news.tintColor) },
                            set: { news.tintColor = sourceHexColor($0) }
                        )).labelsHidden()
                    }
                    .padding(12)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                }
                AppInputField(title: "Caption", text: $news.caption)
                AppInputField(title: "URL", text: $news.url, identifier: true)
                Text("현재 JSON 저장 형식에서는 뉴스 URL이 제외됩니다.")
                    .font(.caption2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Release date").font(.subheadline)
                    DatePicker("Release date", selection: dateBinding, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden().frame(maxWidth: .infinity)
                        .padding(8)
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Notifications").font(.subheadline)
                    Toggle(isOn: $news.notify) { Label("Send notification", systemImage: "bell.fill") }
                        .padding(12)
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Associated app").font(.subheadline)
                    if let app = apps.first(where: { $0.bundleIdentifier == news.appID }) {
                        AssociatedAppCard(app: app, actionTitle: "UNLINK") { news.appID = "" }
                    } else {
                        Button { choosingApp = true } label: { Label("Attach application", systemImage: "plus") }
                            .frame(maxWidth: .infinity, minHeight: 64)
                            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
            .padding(16).frame(maxWidth: 780).frame(maxWidth: .infinity)
        }
        .navigationTitle("News editor")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $choosingApp) {
            AssociatedAppPicker(apps: apps) { news.appID = $0.bundleIdentifier; choosingApp = false }
        }
        .confirmationDialog("이 뉴스를 삭제할까요?", isPresented: $deleting) {
            Button("삭제", role: .destructive) { dismiss(); deleteAction() }
        }
        .keyboardDismissButton()
    }
}

private struct NewsPosterField: View {
    @Binding var url: String
    @State private var showingURL = false
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Poster (optional)").font(.subheadline)
            Button { showingURL = true } label: {
                ZStack {
                    if url.isEmpty {
                        Label("Add Image", systemImage: "photo").font(.headline)
                    } else {
                        RemoteImage(url: url, systemName: "photo")
                    }
                }
                .frame(maxWidth: .infinity).frame(height: 130)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                .clipShape(RoundedRectangle(cornerRadius: 18))
            }
            if !url.isEmpty { Button("Delete image", role: .destructive) { url = "" }.font(.caption) }
        }
        .alert("Poster image URL", isPresented: $showingURL) {
            TextField("https://example.com/image.png", text: $url)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Done") {}
            Button("Cancel", role: .cancel) {}
        } message: { Text("JSON에 저장할 이미지 주소를 입력하세요.") }
    }
}

private struct AssociatedAppPicker: View {
    @Environment(\.dismiss) private var dismiss
    let apps: [AltApp]
    let select: (AltApp) -> Void
    @State private var search = ""
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(apps.indices.filter { search.isEmpty || apps[$0].name.localizedCaseInsensitiveContains(search) || apps[$0].bundleIdentifier.localizedCaseInsensitiveContains(search) }, id: \.self) { index in
                        AssociatedAppCard(app: apps[index], actionTitle: "ATTACH") { select(apps[index]) }
                    }
                }.padding(16)
            }
            .searchable(text: $search)
            .navigationTitle("Choose Associated App")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("닫기") { dismiss() } }
        }
    }
}

private struct AssociatedAppCard: View {
    let app: AltApp
    let actionTitle: String
    let action: () -> Void
    private var tint: Color { sourceTintColor(app.tintColor) }
    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(url: app.iconURL, systemName: "app.fill")
                .frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name).font(.headline).foregroundStyle(.primary).lineLimit(2)
                Text(app.bundleIdentifier).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button(actionTitle, action: action)
                .font(.caption.bold()).foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(tint, in: Capsule())
        }
        .padding(12).background(tint.opacity(0.22), in: RoundedRectangle(cornerRadius: 19))
    }
}

private func newsDate(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    if let parsed = formatter.date(from: value) { return parsed }
    let day = DateFormatter()
    day.dateFormat = "yyyy-MM-dd"
    return day.date(from: String(value.prefix(10))) ?? .now
}

private func newsISODate(_ value: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = .current
    return formatter.string(from: value)
}

private func newsDisplayDate(_ value: String) -> String {
    let parts = String(value.prefix(10)).split(separator: "-")
    guard parts.count == 3 else { return value }
    return "\(parts[0])년 \(Int(parts[1]) ?? 0)월 \(Int(parts[2]) ?? 0)일"
}

struct ProjectScreen: View {
    let newAction: () -> Void
    let importAction: () -> Void
    let exportAction: () -> Void
    let viewCodeAction: () -> Void
    private let green = Color(red: 0.02, green: 0.71, blue: 0.57)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(spacing: 10) {
                    Image(systemName: "hammer.fill").font(.title2).foregroundStyle(.purple)
                    Text("Project").font(.title2.bold())
                }
                .frame(maxWidth: .infinity).padding(.vertical, 17)
                .background(LinearGradient(colors: [Color.mint.opacity(0.1), Color.mint.opacity(0.35)], startPoint: .leading, endPoint: .trailing))
                projectGroup("Actions", rows: [
                    ("folder.badge.plus", "소스 새로 만들기", newAction),
                    ("folder", "JSON 불러오기", importAction),
                    ("square.and.arrow.up", "JSON 내보내기", exportAction),
                    ("chevron.left.forwardslash.chevron.right", "소스코드 보기", viewCodeAction)
                ])
            }
            .frame(maxWidth: 780).frame(maxWidth: .infinity)
            .padding(.bottom, 30)
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private func projectGroup(_ title: String, rows: [(String, String, () -> Void)]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.bold())
            VStack(spacing: 0) {
                ForEach(rows.indices, id: \.self) { index in
                    Button(action: rows[index].2) {
                        HStack(spacing: 16) {
                            Image(systemName: rows[index].0).frame(width: 24)
                            Text(rows[index].1)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }
                        .font(.title3).foregroundStyle(green)
                        .frame(height: 57).padding(.horizontal, 16)
                        .contentShape(Rectangle())
                    }
                    if index < rows.count - 1 { Divider().padding(.leading, 56) }
                }
            }
            .background(Color.mint.opacity(0.24), in: RoundedRectangle(cornerRadius: 22))
        }
        .padding(.horizontal, 16)
    }
}

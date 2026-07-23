// The Models pane: search + language filter over the catalog, one card per model.

import SwiftUI
import PrivoVoiceKit

struct ModelsPane: View {
    @Environment(AppEnvironment.self) private var env

    @State private var searchText = ""
    @State private var languageFilter: LanguageTag?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(filtered) { spec in
                    ModelCard(spec: spec)
                }
                if filtered.isEmpty {
                    ContentUnavailableView(
                        "No models match",
                        systemImage: "magnifyingglass",
                        description: Text("Try a different search or language."))
                        .padding(.top, 40)
                }
            }
            .padding(16)
        }
        .navigationTitle("Models")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search models")
        .onAppear { env.store.refresh() }   // pick up assets added since launch
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                languageMenu
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    env.store.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Rescan the models folder")
            }
        }
    }

    private var languageMenu: some View {
        Menu {
            Button("All languages") { languageFilter = nil }
            Divider()
            ForEach(ModelCatalog.allLanguages) { lang in
                Button {
                    languageFilter = lang
                } label: {
                    if languageFilter == lang {
                        Label(lang.displayName, systemImage: "checkmark")
                    } else {
                        Text(lang.displayName)
                    }
                }
            }
        } label: {
            Label(languageFilter?.displayName ?? "All languages", systemImage: "globe")
        }
    }

    private var filtered: [ModelSpec] {
        ModelCatalog.all.filter { spec in
            let matchesLanguage = languageFilter.map { spec.languages.contains($0) } ?? true
            let matchesSearch = searchText.isEmpty || {
                let q = searchText.lowercased()
                return spec.displayName.lowercased().contains(q)
                    || spec.summary.lowercased().contains(q)
                    || spec.upstreamRepo.lowercased().contains(q)
                    || spec.languages.contains { $0.displayName.lowercased().contains(q) || $0.code.contains(q) }
            }()
            return matchesLanguage && matchesSearch
        }
    }
}

// The Models pane: models grouped by USE CASE (data-driven from UseCaseCatalog).
// Each use-case section lists its ranked recommendations (1 = recommended, then
// alternates); a trailing "More models" section catches every catalog model no
// profile references, so nothing in the catalog is unreachable. Search + the
// language filter narrow the models WITHIN each section and hide empty sections.

import SwiftUI
import PrivoVoiceKit

struct ModelsPane: View {
    @Environment(AppEnvironment.self) private var env

    @State private var searchText = ""
    @State private var languageFilter: LanguageTag?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                let sections = visibleSections
                ForEach(sections) { section in
                    sectionView(section)
                }
                if sections.isEmpty {
                    ContentUnavailableView(
                        "No models match",
                        systemImage: "magnifyingglass",
                        description: Text("Try a different search or language."))
                        .frame(maxWidth: .infinity)
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

    // MARK: - Sections

    private func sectionView(_ section: UseCaseSection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(section)
            ForEach(section.entries) { entry in
                ModelCard(spec: entry.spec, rank: entry.rank)
            }
        }
    }

    private func sectionHeader(_ section: UseCaseSection) -> some View {
        HStack(spacing: 12) {
            Image(systemName: section.systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(AppTheme.accent)
                .frame(width: 36, height: 36)
                .background(AppTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(section.title)
                    .font(.title3.weight(.bold))
                Text(section.tagline)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Toolbar

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

    // MARK: - Data

    /// One rendered section: a use-case (with ranked entries) or the catch-all.
    private struct UseCaseSection: Identifiable {
        let id: String
        let title: String
        let tagline: String
        let systemImage: String
        let entries: [Entry]

        struct Entry: Identifiable {
            let spec: ModelSpec
            /// Rank within the use case (1 = recommended); `nil` in "More models".
            let rank: Int?
            var id: String { spec.id }
        }
    }

    /// The full, unfiltered section list: every use-case profile in catalog order,
    /// then a "More models" catch-all for anything no profile references.
    private var allSections: [UseCaseSection] {
        var sections: [UseCaseSection] = []
        var featured: Set<String> = []

        for profile in UseCaseCatalog.all {
            var specs: [ModelSpec] = []
            if let recommended = profile.recommendedModel { specs.append(recommended) }
            specs.append(contentsOf: profile.alsoGoodModels)

            // Guard against a model being listed twice within one profile.
            var seen: Set<String> = []
            let entries = specs.compactMap { spec -> UseCaseSection.Entry? in
                guard seen.insert(spec.id).inserted else { return nil }
                return UseCaseSection.Entry(spec: spec, rank: seen.count)
            }
            featured.formUnion(entries.map(\.id))
            sections.append(UseCaseSection(
                id: profile.id,
                title: profile.title,
                tagline: profile.tagline,
                systemImage: profile.systemImage,
                entries: entries))
        }

        let leftover = ModelCatalog.all.filter { !featured.contains($0.id) }
        if !leftover.isEmpty {
            sections.append(UseCaseSection(
                id: "__more-models__",
                title: "More models",
                tagline: "Everything else in the catalog.",
                systemImage: "square.stack.3d.up.fill",
                entries: leftover.map { UseCaseSection.Entry(spec: $0, rank: nil) }))
        }
        return sections
    }

    /// Sections with the search + language filter applied; empty ones drop out.
    private var visibleSections: [UseCaseSection] {
        allSections.compactMap { section in
            let entries = section.entries.filter { matches($0.spec) }
            guard !entries.isEmpty else { return nil }
            return UseCaseSection(
                id: section.id,
                title: section.title,
                tagline: section.tagline,
                systemImage: section.systemImage,
                entries: entries)
        }
    }

    private func matches(_ spec: ModelSpec) -> Bool {
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

//
//  PlaylistRulesView.swift
//  MusicNotifier
//
//  Settings sub-screen for managing custom playlist routing rules. Each rule
//  pipes a filtered subset of new releases (by genre / by release kind) into a
//  specific Apple Music playlist when refresh discovers them.
//

import SwiftUI
import SwiftData
import MusicKit

struct PlaylistRulesView: View {
    @Environment(\.dismiss) private var dismiss
    @Query private var artists: [ArtistData]
    @State private var rules: [PlaylistRule] = []
    @State private var editingRule: PlaylistRule?
    @State private var showingEditor = false

    private var allGenres: [String] {
        let g = artists.flatMap { $0.genres ?? [] }
        return Array(Set(g)).sorted()
    }

    var body: some View {
        List {
            Section {
                Text("Route new releases to specific Apple Music playlists. Each rule filters by genre and/or release kind. A release matching multiple rules is added to all of them.")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.secondary)
                    .listRowBackground(Color.clear)
            }

            if rules.isEmpty {
                Section {
                    Button {
                        editingRule = PlaylistRule(name: "", targetPlaylistID: "", matchGenres: [], matchKinds: [])
                        showingEditor = true
                    } label: {
                        Label("Add rule", systemImage: "plus")
                            .foregroundStyle(AppTheme.accent)
                    }
                    .listRowBackground(AppTheme.surface)
                }
            } else {
                Section {
                    ForEach(rules) { rule in
                        Button {
                            editingRule = rule
                            showingEditor = true
                        } label: {
                            ruleRow(rule)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(AppTheme.surface)
                    }
                    .onDelete(perform: deleteRules)

                    Button {
                        editingRule = PlaylistRule(name: "", targetPlaylistID: "", matchGenres: [], matchKinds: [])
                        showingEditor = true
                    } label: {
                        Label("Add rule", systemImage: "plus")
                            .foregroundStyle(AppTheme.accent)
                    }
                    .listRowBackground(AppTheme.surface)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(AppTheme.background.ignoresSafeArea())
        .navigationTitle("Playlist Rules")
        .navigationBarTitleDisplayMode(.inline)
        .task { rules = PlaylistRulesStore.load() }
        .sheet(isPresented: $showingEditor, onDismiss: { editingRule = nil }) {
            if let rule = editingRule {
                NavigationStack {
                    PlaylistRuleEditor(
                        rule: rule,
                        availableGenres: allGenres,
                        onSave: { updated in
                            upsertRule(updated)
                            showingEditor = false
                        },
                        onCancel: { showingEditor = false }
                    )
                }
            }
        }
    }

    private func ruleRow(_ rule: PlaylistRule) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(rule.name.isEmpty ? "Untitled rule" : rule.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryText)
                Spacer()
                if !rule.enabled {
                    Text("Off")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(AppTheme.elevatedSurface))
                        .foregroundStyle(AppTheme.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.secondary)
            }
            Text("→ Playlist: \(rule.name.isEmpty ? "(unnamed)" : rule.name)")
                .font(.caption)
                .foregroundStyle(AppTheme.accent)
            HStack(spacing: 4) {
                Text(filterSummary(rule))
                    .font(.caption2)
                    .foregroundStyle(AppTheme.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func filterSummary(_ rule: PlaylistRule) -> String {
        let g = rule.matchGenres.isEmpty ? "Any genre" : rule.matchGenres.joined(separator: ", ")
        let k = rule.matchKinds.isEmpty ? "Any kind" : rule.matchKinds.joined(separator: ", ")
        return "\(g) · \(k)"
    }

    private func upsertRule(_ rule: PlaylistRule) {
        if let idx = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[idx] = rule
        } else {
            rules.append(rule)
        }
        PlaylistRulesStore.save(rules)
    }

    private func deleteRules(at offsets: IndexSet) {
        rules.remove(atOffsets: offsets)
        PlaylistRulesStore.save(rules)
    }
}

private struct PlaylistRuleEditor: View {
    @State var rule: PlaylistRule
    let availableGenres: [String]
    let onSave: (PlaylistRule) -> Void
    let onCancel: () -> Void

    private let kinds = ["Album", "EP", "Single", "Compilation", "Live Album", "Remix"]

    var body: some View {
        Form {
            Section {
                TextField("e.g. Hip-Hop drops", text: $rule.name)
            } header: {
                Text("Playlist name")
            } footer: {
                Text("A new Apple Music playlist with this name is created automatically the first time the rule matches a release.")
                    .font(.caption2)
            }

            Section {
                if availableGenres.isEmpty {
                    Text("Genres are populated after the next artwork backfill — leave empty for now.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(availableGenres, id: \.self) { genre in
                        Toggle(genre, isOn: Binding(
                            get: { rule.matchGenres.contains(genre) },
                            set: { isOn in
                                if isOn {
                                    if !rule.matchGenres.contains(genre) { rule.matchGenres.append(genre) }
                                } else {
                                    rule.matchGenres.removeAll { $0 == genre }
                                }
                            }
                        ))
                    }
                }
            } header: {
                Text("Match genres (empty = any)")
            }

            Section("Match release kinds (empty = any)") {
                ForEach(kinds, id: \.self) { kind in
                    Toggle(kind, isOn: Binding(
                        get: { rule.matchKinds.contains(kind) },
                        set: { isOn in
                            if isOn {
                                if !rule.matchKinds.contains(kind) { rule.matchKinds.append(kind) }
                            } else {
                                rule.matchKinds.removeAll { $0 == kind }
                            }
                        }
                    ))
                }
            }

            Section {
                Toggle("Enabled", isOn: $rule.enabled)
            }
        }
        .navigationTitle(rule.name.isEmpty ? "New Rule" : "Edit Rule")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { onCancel() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { onSave(rule) }
                    .disabled(rule.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

import AgentHubCore
import SwiftUI

/// Servers found in agent configs, to adopt into the registry. Importing writes nothing to the agents.
struct ImportSheet: View {
    @Environment(ServerStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var candidates: [ImportCandidate]?
    @State private var selected: Set<String> = []
    @State private var variants: [String: Int] = [:]
    @State private var importing = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Import from agents").font(.headline)
                Text(
                    """
                    Servers already in your agents' configs. Importing only starts managing them in AgentHub: agent \
                    configs stay as they are, key values go to the Keychain.
                    """
                )
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            Divider()

            if let candidates {
                if candidates.isEmpty {
                    ContentUnavailableView(
                        "Nothing new to import",
                        systemImage: "checkmark.circle",
                        description: Text("Every server in your agents' configs is already in AgentHub.")
                    )
                    .frame(maxHeight: .infinity)
                } else {
                    List(candidates) { candidate in
                        CandidateRow(
                            candidate: candidate,
                            selected: Binding(
                                get: { selected.contains(candidate.name) },
                                set: { if $0 { selected.insert(candidate.name) } else { selected.remove(candidate.name) } }
                            ),
                            variant: Binding(
                                get: { variants[candidate.name] ?? candidate.suggestedVariant },
                                set: { variants[candidate.name] = $0 }
                            )
                        )
                    }
                    .listStyle(.inset)
                }
            } else {
                ProgressView("Reading agent configs…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            HStack {
                if let candidates, !candidates.isEmpty {
                    Button(selected.count == candidates.count ? "Select None" : "Select All") {
                        selected = selected.count == candidates.count ? [] : Set(candidates.map(\.name))
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(selected.isEmpty ? "Import" : "Import \(selected.count)") { runImport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty || importing)
            }
            .padding(14)
        }
        .frame(width: 640, height: 560)
        .task {
            let found = await store.findImportCandidates()
            candidates = found
            selected = Set(found.map(\.name))
        }
    }

    private func runImport() {
        guard let candidates else { return }
        let picks =
            candidates
            .filter { selected.contains($0.name) }
            .map { (candidate: $0, variant: variants[$0.name] ?? $0.suggestedVariant) }
        importing = true
        Task {
            await store.importServers(picks)
            importing = false
            dismiss()
        }
    }
}

private struct CandidateRow: View {
    @Environment(ServerStore.self) private var store
    let candidate: ImportCandidate
    @Binding var selected: Bool
    @Binding var variant: Int

    var body: some View {
        let chosen = candidate.variants[variant]
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: $selected)
                .toggleStyle(.checkbox)
                .labelsHidden()
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(candidate.name).fontWeight(.medium)
                    Spacer()
                    Text(agentNames(chosen.agents))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                describe(chosen.found)

                if candidate.variants.count > 1 {
                    Picker("Definition", selection: $variant) {
                        ForEach(candidate.variants.indices, id: \.self) { index in
                            Text("\(agentNames(candidate.variants[index].agents)): \(summary(candidate.variants[index].found))")
                                .tag(index)
                        }
                    }
                    .font(.caption)
                    let others = candidate.variants.indices.filter { $0 != variant }.flatMap { candidate.variants[$0].agents }
                    Text(
                        "Agents differ on this server. \(agentNames(others)) keep\(others.count == 1 ? "s" : "") its own version untouched."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                let secretArgs = chosen.found.secretLikeArguments
                if !secretArgs.isEmpty {
                    Label(
                        "\(secretArgs.joined(separator: ", ")) holds a secret in plain text in the arguments. After import, move it into a key.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func describe(_ found: FoundServer) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: found.server.transport == .stdio ? "terminal" : "globe")
                Text(summary(found)).lineLimit(1).truncationMode(.middle)
            }
            if !found.server.keys.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "key")
                    Text(found.server.keys.joined(separator: ", ")).font(.caption.monospaced())
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// Arguments are shown, but a value right after a secret-looking flag is masked.
    private func summary(_ found: FoundServer) -> String {
        guard found.server.transport == .stdio else { return found.server.url }
        let flagged = Set(found.secretLikeArguments)
        var parts = [found.server.command]
        var maskNext = false
        for arg in found.server.args {
            if maskNext {
                parts.append("•••")
                maskNext = false
            } else if let equals = arg.firstIndex(of: "="), flagged.contains(String(arg[..<equals])) {
                parts.append(String(arg[...equals]) + "•••")
            } else {
                parts.append(arg)
                maskNext = flagged.contains(arg)
            }
        }
        return CommandLineParser.join(parts)
    }

    private func agentNames(_ ids: [AgentID]) -> String {
        ids.map { id in store.agents.first { $0.id == id }?.name ?? id.rawValue }.joined(separator: ", ")
    }
}

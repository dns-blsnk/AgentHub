import AgentHubCore
import SwiftUI

/// Saved accounts of every agent AgentHub switches, with switch / add / forget.
struct AccountsView: View {
    @Environment(AllAccounts.self) private var all

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Accounts").font(.headline)
                    Text("The account in use is saved automatically; switch between saved ones in a click.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { for model in all.models { await model.refresh() } } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Re-read the current sign-ins")
            }
            .padding(16)
            Divider()

            ScrollView {
                VStack(spacing: 14) {
                    ForEach(all.models) { model in
                        AccountsSection(model: model)
                    }
                }
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { Task { for model in all.models { await model.refresh() } } }
    }
}

private struct AccountsSection: View {
    let model: AccountsModel
    @State private var forgetting: SavedAccount?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.kind.name).font(.title3.weight(.semibold))
                if model.runningSessions > 0 {
                    Text("\(model.runningSessions) running").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("Add Account…") { Task { await model.startAdding() } }
                    .disabled(model.adding || model.busy)
            }

            if model.adding {
                AddingBanner(model: model)
            }

            if model.accounts.isEmpty && !model.adding {
                Text("No accounts yet. Sign in to \(model.kind.name) once, or press Add Account.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.accounts) { account in
                AccountRow(model: model, account: account, forgetting: $forgetting)
                if account.id != model.accounts.last?.id { Divider() }
            }

            if let message = model.message {
                HStack(alignment: .top) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text(message).textSelection(.enabled)
                    Spacer()
                    Button("Dismiss") { model.message = nil }.buttonStyle(.borderless)
                }
                .font(.callout)
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .disabled(model.busy)
        .confirmationDialog(
            "Forget \(forgetting?.email ?? "")?",
            isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
            presenting: forgetting
        ) { account in
            Button("Forget", role: .destructive) { Task { await model.forget(account) } }
        } message: { account in
            Text("AgentHub deletes its saved copy of \(account.email). To use it again you'll have to sign in again.")
        }
    }
}

private struct AccountRow: View {
    let model: AccountsModel
    let account: SavedAccount
    @Binding var forgetting: SavedAccount?

    var body: some View {
        let active = account.email == model.activeEmail
        HStack(spacing: 10) {
            Image(systemName: active ? "checkmark.circle.fill" : "person.crop.circle")
                .foregroundStyle(active ? .green : .secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.email).fontWeight(active ? .semibold : .regular)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if active {
                Text("In use").font(.caption).foregroundStyle(.green)
            } else {
                Button("Switch") { Task { await model.switchTo(account) } }
            }
            Menu {
                Button("Forget…", role: .destructive) { forgetting = account }
                    .disabled(active)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .disabled(model.adding)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { Task { await model.switchTo(account) } }
    }

    private var detail: String {
        var parts: [String] = []
        if !account.authMethod.isEmpty { parts.append(account.authMethod) }
        if let used = account.lastUsedAt {
            parts.append("used \(used.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: " · ")
    }
}

private struct AddingBanner: View {
    let model: AccountsModel

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("Waiting for sign-in…").fontWeight(.medium)
                Text("Sign in with the new account in the Terminal window that opened. It's added as soon as \(model.kind.name) saves it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { Task { await model.cancelAdding() } }
        }
        .padding(10)
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

#Preview {
    AccountsView()
        .environment(AllAccounts.preview())
        .frame(width: 720, height: 520)
}

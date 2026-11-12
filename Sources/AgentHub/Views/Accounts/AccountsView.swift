import AgentHubCore
import SwiftUI

/// Saved accounts of every agent AgentHub switches, with switch / add / forget.
struct AccountsView: View {
    @Environment(AccountsStore.self) private var accounts

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Accounts").font(.headline)
                    Text("The account in use is saved automatically; switch between saved ones in a click.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await accounts.refreshAll() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Re-read the current sign-ins")
            }
            .padding(16)
            Divider()

            ScrollView {
                VStack(spacing: 14) {
                    ForEach(accounts.agents) { agent in
                        AccountsSection(agent: agent)
                    }
                }
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { Task { await accounts.refreshAll() } }
    }
}

private struct AccountsSection: View {
    let agent: AgentAccounts
    @Environment(AccountsStore.self) private var accounts
    @State private var forgetting: SavedAccount?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(agent.name).font(.title3.weight(.semibold))
                if agent.runningSessions > 0 {
                    Text("\(agent.runningSessions) running").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if agent.busy { ProgressView().controlSize(.small) }
                Button("Add Account…") { Task { await accounts.startAdding(for: agent.id) } }
                    .disabled(agent.adding || agent.busy)
            }

            if agent.adding {
                AddingBanner(agent: agent)
            }

            if agent.accounts.isEmpty && !agent.adding {
                Text("No accounts yet. Sign in to \(agent.name) once, or press Add Account.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(agent.accounts) { account in
                AccountRow(agent: agent, account: account, forgetting: $forgetting)
                if account.id != agent.accounts.last?.id { Divider() }
            }

            if let message = agent.message {
                HStack(alignment: .top) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text(message).textSelection(.enabled)
                    Spacer()
                    Button("Dismiss") { accounts.dismissMessage(for: agent.id) }.buttonStyle(.borderless)
                }
                .font(.callout)
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .disabled(agent.busy)
        .confirmationDialog(
            "Forget \(forgetting?.email ?? "")?",
            isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
            presenting: forgetting
        ) { account in
            Button("Forget", role: .destructive) { Task { await accounts.forget(account, for: agent.id) } }
        } message: { account in
            Text("AgentHub deletes its saved copy of \(account.email). To use it again you'll have to sign in again.")
        }
    }
}

private struct AccountRow: View {
    let agent: AgentAccounts
    let account: SavedAccount
    @Binding var forgetting: SavedAccount?
    @Environment(AccountsStore.self) private var accounts

    var body: some View {
        let active = account.email == agent.activeEmail
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
                Button("Switch") { Task { await accounts.switchTo(account, for: agent.id) } }
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
        .disabled(agent.adding)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { Task { await accounts.switchTo(account, for: agent.id) } }
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
    let agent: AgentAccounts
    @Environment(AccountsStore.self) private var accounts

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("Waiting for sign-in…").fontWeight(.medium)
                Text("Sign in with the new account in the Terminal window that opened. It's added as soon as \(agent.name) saves it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { Task { await accounts.cancelAdding(for: agent.id) } }
        }
        .padding(10)
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

#Preview {
    AccountsView()
        .environment(AccountsStore.preview())
        .frame(width: 720, height: 520)
}

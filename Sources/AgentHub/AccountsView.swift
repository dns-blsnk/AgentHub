import AgentHubCore
import SwiftUI

/// Saved Antigravity CLI accounts with switch / add / remove.
struct AccountsView: View {
    @Environment(AccountsModel.self) private var model
    @State private var forgetting: AntigravityAccount?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Antigravity accounts").font(.headline)
                    Text("Switches the Google account the `agy` CLI signs in with.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await model.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Re-read the current sign-in")
                Button("Add Account…") { Task { await model.startAdding() } }
                    .disabled(model.adding || model.busy)
            }
            .padding(16)
            Divider()

            if model.adding {
                AddingBanner()
                Divider()
            }

            if model.accounts.isEmpty && !model.adding {
                ContentUnavailableView {
                    Label("No accounts yet", systemImage: "person.crop.circle.badge.plus")
                } description: {
                    Text("Sign in with `agy` once, or press Add Account. The account in use is saved automatically.")
                }
            } else {
                List(model.accounts) { account in
                    AccountRow(account: account, forgetting: $forgetting)
                }
                .listStyle(.inset)
            }

            if let message = model.message {
                Divider()
                HStack {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text(message).textSelection(.enabled)
                    Spacer()
                    Button("Dismiss") { model.message = nil }
                }
                .font(.callout)
                .padding(10)
            }
        }
        .disabled(model.busy)
        .onAppear { Task { await model.refresh() } }
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
    @Environment(AccountsModel.self) private var model
    let account: AntigravityAccount
    @Binding var forgetting: AntigravityAccount?

    var body: some View {
        let active = account.email == model.activeEmail
        HStack(spacing: 10) {
            Image(systemName: active ? "checkmark.circle.fill" : "person.crop.circle")
                .foregroundStyle(active ? .green : .secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.email).fontWeight(active ? .semibold : .regular)
                Text(detail(active: active)).font(.caption).foregroundStyle(.secondary)
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
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { Task { await model.switchTo(account) } }
    }

    private func detail(active: Bool) -> String {
        var parts = [account.authMethod.isEmpty ? "Google" : account.authMethod]
        if active, model.runningSessions > 0 {
            parts.append("\(model.runningSessions) agy session(s) running")
        } else if let used = account.lastUsedAt {
            parts.append("used \(used.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: " · ")
    }
}

private struct AddingBanner: View {
    @Environment(AccountsModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("Waiting for sign-in…").fontWeight(.medium)
                Text("Sign in with the new account in the Terminal window that opened. It's added as soon as agy saves it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { Task { await model.cancelAdding() } }
        }
        .padding(12)
        .background(.blue.opacity(0.08))
    }
}

#Preview {
    AccountsView()
        .environment(AccountsModel.preview())
        .frame(width: 620, height: 380)
}

import AgentHubCore
import SwiftUI

/// One checkmark per saved account; picking another switches to it. Used in menus (menu bar, notch).
struct AccountToggles: View {
    let agent: AgentAccounts
    @Environment(AccountsStore.self) private var accounts

    var body: some View {
        ForEach(agent.accounts) { account in
            Toggle(account.email, isOn: Binding(
                get: { account.email == agent.activeEmail },
                set: { if $0 { Task { await accounts.switchTo(account, for: agent.id) } } }
            ))
            .disabled(agent.adding)
        }
    }
}

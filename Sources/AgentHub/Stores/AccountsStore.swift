import AgentHubCore
import AppKit
import Foundation
import Observation

/// What differs between agents whose accounts AgentHub switches.
struct AccountKind: Sendable {
    let agent: AgentID
    /// The CLI and its login arguments, run in Terminal by "Add Account".
    let tool: String
    let loginArguments: [String]
    let slot: any SignInSlot
    let vault: AccountVault
    /// Agents that rewrite their sign-in while running (token refresh, state file on exit) would undo a switch.
    let blocksWhileRunning: Bool

    static let all: [AccountKind] = [
        AccountKind(
            agent: .claude, tool: "claude", loginArguments: ["auth", "login"],
            slot: ClaudeSignInSlot(), vault: .claude(), blocksWhileRunning: true),
        AccountKind(
            agent: .codex, tool: "codex", loginArguments: ["login"],
            slot: CodexAuthSlot(), vault: .codex(), blocksWhileRunning: true),
        AccountKind(
            agent: .antigravity, tool: "agy", loginArguments: [],
            slot: AntigravityKeyring(), vault: .antigravity(), blocksWhileRunning: false),
    ]
}

/// One agent's accounts as the views see them.
struct AgentAccounts: Identifiable {
    let kind: AccountKind
    var accounts: [SavedAccount] = []
    var activeEmail: String?
    /// Sessions of this agent running right now.
    var runningSessions = 0
    var adding = false
    var busy = false
    var message: String?

    var id: AgentID { kind.agent }
    var name: String { kind.agent.displayName }
}

/// Saved accounts of every agent AgentHub switches: which one is in use, the saved ones, and the "add account" flow.
@MainActor
@Observable
final class AccountsStore {
    /// In display order.
    private(set) var agents: [AgentAccounts]

    @ObservationIgnored private var previousEmail: [AgentID: String] = [:]
    @ObservationIgnored private var pollTasks: [AgentID: Task<Void, Never>] = [:]
    private var isPreview = false

    init(kinds: [AccountKind] = AccountKind.all) {
        agents = kinds.map { AgentAccounts(kind: $0) }
        Task { await refreshAll() }
    }

    private init(preview: Void) {
        isPreview = true
        agents = AccountKind.all.prefix(2).map { kind in
            var state = AgentAccounts(kind: kind)
            state.accounts = [
                SavedAccount(email: "me@example.com", authMethod: "pro", addedAt: .now, lastUsedAt: .now),
                SavedAccount(email: "work@example.com", authMethod: "max", addedAt: .now.addingTimeInterval(-86_400), lastUsedAt: nil),
            ]
            state.activeEmail = "me@example.com"
            state.runningSessions = 1
            return state
        }
    }

    static func preview() -> AccountsStore { AccountsStore(preview: ()) }

    /// Agents with at least one saved account, for the quick switchers.
    var switchable: [AgentAccounts] { agents.filter { !$0.accounts.isEmpty } }

    func refreshAll() async {
        for state in agents { await refresh(state.id) }
    }

    /// Re-reads the agent's current sign-in and saves it, so the account in use is always in the list.
    func refresh(_ agent: AgentID) async {
        guard !isPreview, let kind = kind(agent) else { return }
        let switcher = Self.switcher(kind)
        let result = await Task.detached { () -> Result<(String?, [SavedAccount], Int), Error> in
            Result {
                let current = try switcher.captureCurrent()
                return (current?.email, switcher.vault.load(), Self.runningSessions(of: agent))
            }
        }.value
        update(agent) { state in
            switch result {
            case .success(let (email, accounts, sessions)):
                // While adding, the slot is empty on purpose; don't report the previous account as active.
                if !state.adding { state.activeEmail = email }
                state.accounts = accounts.sorted { $0.addedAt < $1.addedAt }
                state.runningSessions = sessions
            case .failure(let error):
                state.message = error.localizedDescription
            }
        }
    }

    func switchTo(_ account: SavedAccount, for agent: AgentID) async {
        guard !isPreview, let state = state(agent), !state.adding, account.email != state.activeEmail else { return }
        guard await allowedToChange(agent) else { return }
        await perform(agent) { try $0.switchTo(account.email) }
        if let state = self.state(agent), state.message == nil, state.runningSessions > 0 {
            update(agent) {
                $0.message =
                    "Switched to \(account.email). \($0.runningSessions) running \($0.name) session(s) still use the previous account until restarted."
            }
        }
    }

    /// Only inactive accounts: the active one would be re-saved by the next refresh anyway.
    func forget(_ account: SavedAccount, for agent: AgentID) async {
        guard !isPreview, account.email != state(agent)?.activeEmail else { return }
        await perform(agent) { try $0.vault.forget(account.email) }
    }

    /// Clears the agent's sign-in (after saving the current account) and opens Terminal with the agent's login.
    /// The new sign-in is picked up as soon as it appears.
    func startAdding(for agent: AgentID) async {
        guard !isPreview, let kind = kind(agent), state(agent)?.adding == false else { return }
        guard await allowedToChange(agent) else { return }
        let switcher = Self.switcher(kind)
        let result = await Task.detached { Result { try switcher.beginAdding() } }.value
        switch result {
        case .success(let previous):
            previousEmail[agent] = previous?.email
            update(agent) {
                $0.activeEmail = nil
                $0.adding = true
                $0.message = nil
            }
            openSignInTerminal(kind)
            pollForSignIn(kind)
        case .failure(let error):
            update(agent) { $0.message = error.localizedDescription }
        }
    }

    /// Gives up on adding and puts the previous account back.
    func cancelAdding(for agent: AgentID) async {
        pollTasks[agent]?.cancel()
        update(agent) { $0.adding = false }
        if let previous = previousEmail.removeValue(forKey: agent) {
            await perform(agent) { try $0.activate(previous) }
        }
    }

    func dismissMessage(for agent: AgentID) {
        update(agent) { $0.message = nil }
    }

    // MARK: Internals

    private func state(_ agent: AgentID) -> AgentAccounts? { agents.first { $0.id == agent } }
    private func kind(_ agent: AgentID) -> AccountKind? { state(agent)?.kind }

    private func update(_ agent: AgentID, _ change: (inout AgentAccounts) -> Void) {
        guard let index = agents.firstIndex(where: { $0.id == agent }) else { return }
        change(&agents[index])
    }

    private static func switcher(_ kind: AccountKind) -> AccountSwitcher {
        AccountSwitcher(slot: kind.slot, vault: kind.vault)
    }

    /// Claude Code and Codex rewrite their sign-in while they run, so changing it under them is refused.
    private func allowedToChange(_ agent: AgentID) async -> Bool {
        guard let kind = kind(agent), kind.blocksWhileRunning else { return true }
        let running = await Task.detached { Self.runningSessions(of: agent) }.value
        update(agent) { $0.runningSessions = running }
        guard running == 0 else {
            update(agent) { $0.message = AccountError.sessionsRunning($0.name, running).localizedDescription }
            return false
        }
        return true
    }

    private func pollForSignIn(_ kind: AccountKind) {
        let agent = kind.agent
        pollTasks[agent]?.cancel()
        let slot = kind.slot
        pollTasks[agent] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                let signIn = await Task.detached { try? slot.read() }.value
                guard let signIn, signIn.email != nil else { continue }
                guard let self else { return }
                self.update(agent) { $0.adding = false }
                self.previousEmail[agent] = nil
                await self.refresh(agent)
                self.update(agent) { $0.message = "Added \(signIn.email ?? "account"). You can close the Terminal window." }
                return
            }
        }
    }

    private func openSignInTerminal(_ kind: AccountKind) {
        let tool = Self.runner.which(kind.tool)?.path ?? kind.tool
        let script = AppPaths.support.appendingPathComponent("\(kind.agent.rawValue)-sign-in.command")
        let body = """
            #!/bin/zsh -l
            echo "AgentHub: sign in to \(kind.agent.displayName) with the account you want to add."
            echo "AgentHub picks it up automatically; close this window afterwards."
            echo
            exec \(CommandLineParser.join([tool] + kind.loginArguments))

            """
        do {
            try PrivateFiles.makeDirectory(AppPaths.support)
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
        } catch {
            let command = ([kind.tool] + kind.loginArguments).joined(separator: " ")
            update(kind.agent) {
                $0.message = "Couldn't open Terminal: \(error.localizedDescription). Run `\(command)` yourself to sign in."
            }
        }
    }

    private func perform(_ agent: AgentID, _ action: @escaping @Sendable (AccountSwitcher) throws -> Void) async {
        guard let kind = kind(agent) else { return }
        update(agent) { $0.busy = true }
        let switcher = Self.switcher(kind)
        let result = await Task.detached { Result { try action(switcher) } }.value
        update(agent) {
            $0.busy = false
            if case .failure(let error) = result { $0.message = error.localizedDescription } else { $0.message = nil }
        }
        await refresh(agent)
    }

    /// Detected once (a login shell is slow); the first refresh warms it up off the main thread.
    nonisolated private static let runner = CommandRunner.detect()

    nonisolated private static func runningSessions(of agent: AgentID) -> Int {
        SessionScanner().scan().filter { $0.agent == agent }.count
    }
}

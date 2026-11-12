import AgentHubCore
import AppKit
import Foundation
import Observation

/// What differs between agents whose accounts AgentHub switches.
struct AccountKind: Sendable {
    let agent: AgentID
    let name: String
    /// The CLI and its login arguments, run in Terminal by "Add Account".
    let tool: String
    let loginArguments: [String]
    let slot: any SignInSlot
    let store: AccountStore
    /// Agents that rewrite their sign-in while running (token refresh, state file on exit) would undo a switch.
    let blocksWhileRunning: Bool

    static let antigravity = AccountKind(agent: .antigravity, name: "Antigravity", tool: "agy", loginArguments: [],
                                         slot: AntigravityKeyring(), store: .antigravity(), blocksWhileRunning: false)
    static let claude = AccountKind(agent: .claude, name: "Claude Code", tool: "claude", loginArguments: ["auth", "login"],
                                    slot: ClaudeSignInSlot(), store: .claude(), blocksWhileRunning: true)
    static let codex = AccountKind(agent: .codex, name: "Codex", tool: "codex", loginArguments: ["login"],
                                   slot: CodexAuthSlot(), store: .codex(), blocksWhileRunning: true)
}

/// The accounts of every agent AgentHub can switch, in display order.
@MainActor
@Observable
final class AllAccounts {
    let models: [AccountsModel]

    init(_ models: [AccountsModel]) { self.models = models }

    static func live() -> AllAccounts { AllAccounts([AccountsModel(.claude), AccountsModel(.codex), AccountsModel(.antigravity)]) }
    static func preview() -> AllAccounts { AllAccounts([AccountsModel.preview(.claude), AccountsModel.preview(.antigravity)]) }

    func model(for agent: AgentID) -> AccountsModel? { models.first { $0.kind.agent == agent } }
}

/// One agent's accounts: which one is in use, the saved ones, and the "add account" flow.
@MainActor
@Observable
final class AccountsModel: Identifiable {
    let kind: AccountKind
    var accounts: [SavedAccount] = []
    var activeEmail: String?
    /// Sessions of this agent running right now.
    var runningSessions = 0
    var adding = false
    var busy = false
    var message: String?

    nonisolated var id: AgentID { kind.agent }

    private let switcher: AccountSwitcher
    private var previousEmail: String?
    private var pollTask: Task<Void, Never>?
    private var isPreview = false

    init(_ kind: AccountKind) {
        self.kind = kind
        switcher = AccountSwitcher(slot: kind.slot, store: kind.store)
        Task { await refresh() }
    }

    private init(preview kind: AccountKind) {
        self.kind = kind
        switcher = AccountSwitcher(slot: kind.slot, store: kind.store)
        isPreview = true
        accounts = [
            SavedAccount(email: "me@example.com", authMethod: "pro", addedAt: .now, lastUsedAt: .now),
            SavedAccount(email: "work@example.com", authMethod: "max", addedAt: .now.addingTimeInterval(-86_400), lastUsedAt: nil),
        ]
        activeEmail = "me@example.com"
        runningSessions = 1
    }

    static func preview(_ kind: AccountKind) -> AccountsModel { AccountsModel(preview: kind) }

    /// Re-reads the agent's current sign-in and saves it, so the account in use is always in the list.
    func refresh() async {
        guard !isPreview else { return }
        let switcher = self.switcher
        let agent = kind.agent
        let result = await Task.detached { () -> Result<(String?, [SavedAccount], Int), Error> in
            Result {
                let current = try switcher.captureCurrent()
                return (current?.email, switcher.store.load(), Self.runningSessions(of: agent))
            }
        }.value
        switch result {
        case .success(let (email, accounts, sessions)):
            // While adding, the slot is empty on purpose; don't report the previous account as active.
            if !adding { activeEmail = email }
            self.accounts = accounts.sorted { $0.addedAt < $1.addedAt }
            runningSessions = sessions
        case .failure(let error):
            message = error.localizedDescription
        }
    }

    func switchTo(_ account: SavedAccount) async {
        // While adding, the agent is signed out on purpose and the poll waits for the new sign-in.
        guard !isPreview, !adding, account.email != activeEmail else { return }
        guard await allowedToChange() else { return }
        await perform { try $0.switchTo(account.email) }
        if message == nil && runningSessions > 0 {
            message = "Switched to \(account.email). \(runningSessions) running \(kind.name) session(s) still use the previous account until restarted."
        }
    }

    /// Only inactive accounts: the active one would be re-saved by the next refresh anyway.
    func forget(_ account: SavedAccount) async {
        guard !isPreview, account.email != activeEmail else { return }
        await perform { try $0.store.forget(account.email) }
    }

    /// Clears the agent's sign-in (after saving the current account) and opens Terminal with the agent's login.
    /// The new sign-in is picked up as soon as it appears.
    func startAdding() async {
        guard !isPreview, !adding else { return }
        guard await allowedToChange() else { return }
        let switcher = self.switcher
        let result = await Task.detached { Result { try switcher.beginAdding() } }.value
        switch result {
        case .success(let previous):
            previousEmail = previous?.email
            activeEmail = nil
            adding = true
            message = nil
            openSignInTerminal()
            pollForSignIn()
        case .failure(let error):
            message = error.localizedDescription
        }
    }

    /// Gives up on adding and puts the previous account back.
    func cancelAdding() async {
        pollTask?.cancel()
        adding = false
        if let previousEmail {
            await perform { try $0.activate(previousEmail) }
        }
        previousEmail = nil
    }

    /// Claude Code and Codex rewrite their sign-in while they run, so changing it under them is refused.
    private func allowedToChange() async -> Bool {
        guard kind.blocksWhileRunning else { return true }
        let agent = kind.agent
        let running = await Task.detached { Self.runningSessions(of: agent) }.value
        runningSessions = running
        guard running == 0 else {
            message = AccountError.sessionsRunning(kind.name, running).localizedDescription
            return false
        }
        return true
    }

    private func pollForSignIn() {
        pollTask?.cancel()
        let slot = kind.slot
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                let signIn = await Task.detached { try? slot.read() }.value
                guard let signIn, signIn.email != nil else { continue }
                guard let self else { return }
                self.adding = false
                self.previousEmail = nil
                await self.refresh()
                self.message = "Added \(signIn.email ?? "account"). You can close the Terminal window."
                return
            }
        }
    }

    private func openSignInTerminal() {
        let tool = Self.runner.which(kind.tool)?.path ?? kind.tool
        let script = AppPaths.support.appendingPathComponent("\(kind.agent.rawValue)-sign-in.command")
        let body = """
        #!/bin/zsh -l
        echo "AgentHub: sign in to \(kind.name) with the account you want to add."
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
            message = "Couldn't open Terminal: \(error.localizedDescription). Run `\(([kind.tool] + kind.loginArguments).joined(separator: " "))` yourself to sign in."
        }
    }

    private func perform(_ action: @escaping @Sendable (AccountSwitcher) throws -> Void) async {
        busy = true
        let switcher = self.switcher
        let result = await Task.detached { Result { try action(switcher) } }.value
        busy = false
        if case .failure(let error) = result {
            message = error.localizedDescription
        } else {
            message = nil
        }
        await refresh()
    }

    /// Detected once (a login shell is slow); the first `refresh()` warms it up off the main thread.
    nonisolated private static let runner = CommandRunner.detect()

    nonisolated private static func runningSessions(of agent: AgentID) -> Int {
        SessionScanner().scan().filter { $0.agent == agent }.count
    }
}

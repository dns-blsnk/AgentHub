import AgentHubCore
import AppKit
import Foundation
import Observation

/// Antigravity CLI accounts: which one `agy` uses now, the saved ones, and the "add account" flow.
@MainActor
@Observable
final class AccountsModel {
    var accounts: [AntigravityAccount] = []
    var activeEmail: String?
    /// `agy` processes running right now; they keep the old account until restarted.
    var runningSessions = 0
    var adding = false
    var busy = false
    var message: String?

    private let switcher = AntigravityAccountSwitcher(store: AntigravityAccountStore(metadataURL: AppPaths.antigravityAccounts))
    private var previousEmail: String?
    private var pollTask: Task<Void, Never>?
    private var isPreview = false

    init() {
        Task { await refresh() }
    }

    private init(preview: Void) {
        isPreview = true
        accounts = [
            AntigravityAccount(email: "me@example.com", authMethod: "consumer", addedAt: .now, lastUsedAt: .now),
            AntigravityAccount(email: "work@example.com", authMethod: "consumer", addedAt: .now.addingTimeInterval(-86_400), lastUsedAt: nil),
        ]
        activeEmail = "me@example.com"
        runningSessions = 1
    }

    static func preview() -> AccountsModel { AccountsModel(preview: ()) }

    /// Re-reads agy's current sign-in and saves it, so the account in use is always in the list.
    func refresh() async {
        guard !isPreview else { return }
        let switcher = self.switcher
        let result = await Task.detached { () -> Result<(String?, [AntigravityAccount], Int), Error> in
            Result {
                let current = try switcher.captureCurrent()
                return (current?.email, switcher.store.load(), Self.countAgyProcesses())
            }
        }.value
        switch result {
        case .success(let (email, accounts, sessions)):
            activeEmail = email
            self.accounts = accounts.sorted { $0.addedAt < $1.addedAt }
            runningSessions = sessions
        case .failure(let error):
            message = error.localizedDescription
        }
    }

    func switchTo(_ account: AntigravityAccount) async {
        // While adding, agy is signed out on purpose and the poll waits for the new sign-in.
        guard !isPreview, !adding, account.email != activeEmail else { return }
        await perform { try $0.switchTo(account.email) }
        if message == nil && runningSessions > 0 {
            message = "Switched to \(account.email). \(runningSessions) running agy session(s) still use the previous account until restarted."
        }
    }

    /// Only inactive accounts: the active one would be re-saved by the next refresh anyway.
    func forget(_ account: AntigravityAccount) async {
        guard !isPreview, account.email != activeEmail else { return }
        await perform { try $0.store.forget(account.email) }
    }

    /// Signs agy out (after saving the current account) and opens Terminal with `agy` to sign in.
    /// The new sign-in is picked up from the Keychain as soon as it appears.
    func startAdding() async {
        guard !isPreview, !adding else { return }
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

    private func pollForSignIn() {
        pollTask?.cancel()
        let keyring = switcher.keyring
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                let credential = await Task.detached { try? keyring.read() }.value
                guard let credential, credential.email != nil else { continue }
                guard let self else { return }
                self.adding = false
                self.previousEmail = nil
                await self.refresh()
                self.message = "Added \(credential.email ?? "account"). You can close the Terminal window."
                return
            }
        }
    }

    private func openSignInTerminal() {
        let agy = Self.runner.which("agy")?.path ?? "agy"
        let script = AppPaths.support.appendingPathComponent("antigravity-sign-in.command")
        let body = """
        #!/bin/zsh -l
        echo "AgentHub: sign in to Antigravity with the account you want to add."
        echo "AgentHub picks it up automatically; close this window afterwards."
        echo
        exec \(CommandLineParser.join([agy]))

        """
        do {
            try FileManager.default.createDirectory(at: AppPaths.support, withIntermediateDirectories: true)
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
        } catch {
            message = "Couldn't open Terminal: \(error.localizedDescription). Run `agy` yourself to sign in."
        }
    }

    private func perform(_ action: @escaping @Sendable (AntigravityAccountSwitcher) throws -> Void) async {
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

    nonisolated private static func countAgyProcesses() -> Int {
        let output = (try? runner.run("pgrep", ["-x", "agy"])) ?? ""
        return output.split(separator: "\n").count
    }
}

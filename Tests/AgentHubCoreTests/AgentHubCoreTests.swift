@testable import AgentHubCore
import Foundation
import XCTest

final class CodexTOMLTests: XCTestCase {
    let existing = """
    model = "gpt-5"

    # keep me
    [projects."/tmp/repo"]
    trust_level = "trusted"

    [mcp_servers.figma]
    command = "npx"
    args = ["figma"]

    [mcp_servers.figma.env]
    FIGMA_API_KEY = "old"

    [mcp_servers.figma.tools.read]
    approval_mode = "approve"

    [mcp_servers.other]
    url = "https://other.example/mcp"

    """

    func testUpsertReplacesOnlyThatServerAndKeepsForeignSubtables() {
        let server = MCPServer(name: "figma", transport: .stdio, command: "node", args: ["a b.js"], secretKey: "FIGMA_API_KEY")
        let result = CodexTOML.upserting(server, token: "new\"token", in: existing)

        XCTAssertTrue(result.hasPrefix("model = \"gpt-5\"\n\n# keep me\n[projects.\"/tmp/repo\"]\ntrust_level = \"trusted\"\n"))
        XCTAssertTrue(result.contains("[mcp_servers.figma]\ncommand = \"node\"\nargs = [\"a b.js\"]\n\n[mcp_servers.figma.env]\n\"FIGMA_API_KEY\" = \"new\\\"token\""))
        XCTAssertTrue(result.contains("[mcp_servers.figma.tools.read]\napproval_mode = \"approve\""))
        XCTAssertFalse(result.contains("old"))
        XCTAssertTrue(result.contains("[mcp_servers.other]\nurl = \"https://other.example/mcp\""))
        XCTAssertEqual(CodexTOML.serverNames(in: result), ["figma", "other"])
    }

    func testUpsertAppendsNewHTTPServer() {
        let server = MCPServer(name: "gitlab", transport: .http, url: "https://gl.example/mcp", secretKey: "Private-Token")
        let result = CodexTOML.upserting(server, token: "t", in: existing)
        XCTAssertTrue(result.hasSuffix("[mcp_servers.gitlab]\nurl = \"https://gl.example/mcp\"\n\n[mcp_servers.gitlab.http_headers]\n\"Private-Token\" = \"t\"\n"))
        XCTAssertTrue(result.hasPrefix(existing.trimmingCharacters(in: .newlines)))
    }

    func testRemoveDropsAllTablesOfServer() {
        let result = CodexTOML.removing("figma", from: existing)
        XCTAssertFalse(result.contains("figma"))
        XCTAssertTrue(result.contains("[projects.\"/tmp/repo\"]"))
        XCTAssertEqual(CodexTOML.serverNames(in: result), ["other"])
    }

    func testRemoveMissingServerIsNoOp() {
        XCTAssertEqual(CodexTOML.removing("nope", from: existing), existing)
    }

    func testEmptyFile() {
        let server = MCPServer(name: "x", transport: .stdio, command: "x")
        XCTAssertEqual(CodexTOML.upserting(server, token: nil, in: ""), "[mcp_servers.x]\ncommand = \"x\"\nargs = []\n")
    }
}

final class CLIArgumentTests: XCTestCase {
    func testClaudeStdio() {
        let server = MCPServer(name: "gh", transport: .stdio, command: "npx", args: ["-y", "pkg"], secretKey: "GITHUB_TOKEN")
        XCTAssertEqual(
            ClaudeAdapter.addArguments(server, token: "t"),
            ["mcp", "add", "-s", "user", "gh", "-e", "GITHUB_TOKEN=t", "--", "npx", "-y", "pkg"]
        )
    }

    func testClaudeHTTPWithoutToken() {
        let server = MCPServer(name: "s", transport: .http, url: "https://x/mcp", secretKey: "Authorization")
        XCTAssertEqual(ClaudeAdapter.addArguments(server, token: nil), ["mcp", "add", "-s", "user", "-t", "http", "s", "https://x/mcp"])
    }

    func testAntigravityFlagsBeforeName() {
        let server = MCPServer(name: "s", transport: .http, url: "https://x/mcp", secretKey: "Authorization")
        XCTAssertEqual(
            AntigravityAdapter.addArguments(server, token: "Bearer t"),
            ["mcp", "add", "--type", "http", "--header", "Authorization: Bearer t", "s", "https://x/mcp"]
        )
    }
}

final class JSONAdapterTests: XCTestCase {
    func testCursorUpsertAndRemoveKeepOtherKeys() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = home.appendingPathComponent(".cursor/mcp.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"mcpServers":{"mine":{"command":"x"}},"other":1}"#.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: home) }

        let adapter = CursorAdapter(runner: CommandRunner(home: home, searchPath: []))
        let server = MCPServer(name: "remote", transport: .http, url: "https://r/mcp", secretKey: "Authorization")
        try adapter.upsert(server, token: "Bearer t")
        XCTAssertEqual(try adapter.serverNames(), ["mine", "remote"])

        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        XCTAssertEqual(root["other"] as? Int, 1)
        let entry = (root["mcpServers"] as! [String: Any])["remote"] as! [String: Any]
        XCTAssertEqual(entry["url"] as? String, "https://r/mcp")
        XCTAssertEqual(entry["headers"] as? [String: String], ["Authorization": "Bearer t"])

        try adapter.remove(name: "remote")
        XCTAssertEqual(try adapter.serverNames(), ["mine"])
    }

    func testRefusesJSONC() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = home.appendingPathComponent(".gemini/settings.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\n  // comment\n  \"a\": 1\n}".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: home) }

        let adapter = GeminiAdapter(runner: CommandRunner(home: home, searchPath: []))
        XCTAssertThrowsError(try adapter.upsert(MCPServer(name: "x", transport: .stdio, command: "x"), token: nil))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "{\n  // comment\n  \"a\": 1\n}")
    }
}

final class SyncTests: XCTestCase {
    func testOnlyRemovesWhatAgentHubApplied() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = home.appendingPathComponent(".cursor/mcp.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"mcpServers":{"figma":{"command":"hand-made"}}}"#.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: home) }

        let sync = MCPSync(
            adapters: [CursorAdapter(runner: CommandRunner(home: home, searchPath: []))],
            snapshots: SnapshotStore(root: home.appendingPathComponent("snapshots"))
        )
        // Not wanted and never applied: the hand-made entry must survive.
        let result = sync.apply(MCPServer(name: "figma", transport: .stdio, command: "x"), token: nil)
        XCTAssertTrue(result.outcomes.isEmpty)
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("hand-made"))

        // Rename of an applied server removes the old name and writes the new one, with a snapshot.
        let applied = MCPServer(name: "figma2", transport: .stdio, command: "x", agents: [.cursor], appliedAgents: [.cursor])
        let renamed = sync.apply(applied, token: nil, previousName: "figma")
        XCTAssertEqual(renamed.outcomes[.cursor], .applied)
        XCTAssertEqual(try CursorAdapter(runner: CommandRunner(home: home, searchPath: [])).serverNames(), ["figma2"])
        let sessions = try FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent("snapshots").path)
        XCTAssertFalse(sessions.isEmpty)
    }
}

final class CommandLineParserTests: XCTestCase {
    func testSplitAndJoinRoundTrip() {
        let argv = ["npx", "-y", "it's a b", "", "x\\y"]
        XCTAssertEqual(CommandLineParser.split(CommandLineParser.join(argv)), argv)
        XCTAssertEqual(CommandLineParser.split(#"node "/a b/c.js" --flag=1"#), ["node", "/a b/c.js", "--flag=1"])
    }
}

final class AntigravityCredentialTests: XCTestCase {
    func testParsesGoKeyringValue() {
        let json = #"{"token":{"access_token":"a","refresh_token":"r"},"auth_method":"consumer","id_token_email":"me@example.com"}"#
        let credential = AntigravityCredential(raw: "go-keyring-base64:" + Data(json.utf8).base64EncodedString())
        XCTAssertEqual(credential.email, "me@example.com")
        XCTAssertEqual(credential.authMethod, "consumer")
    }

    func testUnknownFormatHasNoEmail() {
        XCTAssertNil(AntigravityCredential(raw: "go-keyring-base64:!!!").email)
        XCTAssertNil(AntigravityCredential(raw: "plain").email)
    }
}

final class PreservationTests: XCTestCase {
    func testCodexKeepsForeignMainKeysIncludingMultiLineValues() {
        let text = """
        [mcp_servers.gh]
        command = "old"
        args = [
          "a",
          "b",
        ]
        startup_timeout_sec = 60
        enabled_tools = [
          "x",
        ]

        [mcp_servers.gh.env]
        T = "old"

        """
        let server = MCPServer(name: "gh", transport: .stdio, command: "new", secretKey: "T")
        let result = CodexTOML.upserting(server, token: "t", in: text)
        XCTAssertEqual(result, """
        [mcp_servers.gh]
        command = "new"
        args = []
        startup_timeout_sec = 60
        enabled_tools = [
          "x",
        ]

        [mcp_servers.gh.env]
        "T" = "t"

        """)
    }

    func testJSONKeepsForeignEntryKeysAndSymlink() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let real = home.appendingPathComponent("dotfiles/mcp.json")
        let link = home.appendingPathComponent(".cursor/mcp.json")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"mcpServers":{"gh":{"command":"old","args":["x"],"timeout":30}}}"#.utf8).write(to: real)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: real.path)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: home) }

        let adapter = CursorAdapter(runner: CommandRunner(home: home, searchPath: []))
        try adapter.upsert(MCPServer(name: "gh", transport: .http, url: "https://x/mcp"), token: nil)

        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), real.path)
        let perms = try FileManager.default.attributesOfItem(atPath: real.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: real)) as! [String: Any]
        let entry = (root["mcpServers"] as! [String: Any])["gh"] as! [String: Any]
        XCTAssertEqual(entry["timeout"] as? Int, 30)
        XCTAssertEqual(entry["url"] as? String, "https://x/mcp")
        XCTAssertNil(entry["command"])
    }
}

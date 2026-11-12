import Foundation
import XCTest

@testable import AgentHubCore

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
        let server = MCPServer(name: "figma", transport: .stdio, command: "node", args: ["a b.js"], keys: ["FIGMA_API_KEY"])
        let result = CodexTOML.upserting(server, values: ["FIGMA_API_KEY": "new\"token"], in: existing)

        XCTAssertTrue(result.hasPrefix("model = \"gpt-5\"\n\n# keep me\n[projects.\"/tmp/repo\"]\ntrust_level = \"trusted\"\n"))
        XCTAssertTrue(
            result.contains(
                "[mcp_servers.figma]\ncommand = \"node\"\nargs = [\"a b.js\"]\n\n[mcp_servers.figma.env]\n\"FIGMA_API_KEY\" = \"new\\\"token\""
            ))
        XCTAssertTrue(result.contains("[mcp_servers.figma.tools.read]\napproval_mode = \"approve\""))
        XCTAssertFalse(result.contains("old"))
        XCTAssertTrue(result.contains("[mcp_servers.other]\nurl = \"https://other.example/mcp\""))
        XCTAssertEqual(CodexTOML.serverNames(in: result), ["figma", "other"])
    }

    func testUpsertAppendsNewHTTPServer() {
        let server = MCPServer(name: "gitlab", transport: .http, url: "https://gl.example/mcp", keys: ["Private-Token"])
        let result = CodexTOML.upserting(server, values: ["Private-Token": "t"], in: existing)
        XCTAssertTrue(
            result.hasSuffix(
                "[mcp_servers.gitlab]\nurl = \"https://gl.example/mcp\"\n\n[mcp_servers.gitlab.http_headers]\n\"Private-Token\" = \"t\"\n"))
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
        XCTAssertEqual(CodexTOML.upserting(server, values: [:], in: ""), "[mcp_servers.x]\ncommand = \"x\"\nargs = []\n")
    }
}

final class CLIArgumentTests: XCTestCase {
    func testClaudeStdio() {
        let server = MCPServer(name: "gh", transport: .stdio, command: "npx", args: ["-y", "pkg"], keys: ["GITHUB_TOKEN"])
        XCTAssertEqual(
            ClaudeAdapter.addArguments(server, values: ["GITHUB_TOKEN": "t"]),
            ["mcp", "add", "-s", "user", "gh", "-e", "GITHUB_TOKEN=t", "--", "npx", "-y", "pkg"]
        )
    }

    func testClaudeHTTPWithoutToken() {
        let server = MCPServer(name: "s", transport: .http, url: "https://x/mcp", keys: ["Authorization"])
        XCTAssertEqual(ClaudeAdapter.addArguments(server, values: [:]), ["mcp", "add", "-s", "user", "-t", "http", "s", "https://x/mcp"])
    }

    func testAntigravityFlagsBeforeName() {
        let server = MCPServer(name: "s", transport: .http, url: "https://x/mcp", keys: ["Authorization"])
        XCTAssertEqual(
            AntigravityAdapter.addArguments(server, values: ["Authorization": "Bearer t"]),
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
        let server = MCPServer(name: "remote", transport: .http, url: "https://r/mcp", keys: ["Authorization"])
        try adapter.upsert(server, values: ["Authorization": "Bearer t"])
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
        XCTAssertThrowsError(try adapter.upsert(MCPServer(name: "x", transport: .stdio, command: "x"), values: [:]))
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
        let result = sync.apply(MCPServer(name: "figma", transport: .stdio, command: "x"), values: [:])
        XCTAssertTrue(result.outcomes.isEmpty)
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("hand-made"))

        // Rename of an applied server removes the old name and writes the new one, with a snapshot.
        let applied = MCPServer(name: "figma2", transport: .stdio, command: "x", agents: [.cursor], appliedAgents: [.cursor])
        let renamed = sync.apply(applied, values: [:], previousName: "figma")
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
        let server = MCPServer(name: "gh", transport: .stdio, command: "new", keys: ["T"])
        let result = CodexTOML.upserting(server, values: ["T": "t"], in: text)
        XCTAssertEqual(
            result,
            """
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
        try adapter.upsert(MCPServer(name: "gh", transport: .http, url: "https://x/mcp"), values: [:])

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

final class MultipleKeysTests: XCTestCase {
    let server = MCPServer(name: "figma", transport: .stdio, command: "npx", args: ["figma"], keys: ["FIGMA_TOKEN", "FIGMA_TEAM", "UNSET"])
    let values = ["FIGMA_TOKEN": "t", "FIGMA_TEAM": "42", "STALE": "x"]

    func testEveryKeyWithAValueReachesEachAgentFormat() {
        XCTAssertEqual(
            ClaudeAdapter.addArguments(server, values: values),
            ["mcp", "add", "-s", "user", "figma", "-e", "FIGMA_TOKEN=t", "-e", "FIGMA_TEAM=42", "--", "npx", "figma"]
        )
        XCTAssertEqual(
            AntigravityAdapter.addArguments(server, values: values),
            ["mcp", "add", "--env", "FIGMA_TOKEN=t", "--env", "FIGMA_TEAM=42", "figma", "--", "npx", "figma"]
        )
        XCTAssertEqual(
            CodexTOML.upserting(server, values: values, in: ""),
            "[mcp_servers.figma]\ncommand = \"npx\"\nargs = [\"figma\"]\n\n[mcp_servers.figma.env]\n\"FIGMA_TOKEN\" = \"t\"\n\"FIGMA_TEAM\" = \"42\"\n"
        )
        XCTAssertEqual(CursorAdapter.entry(server, values: values)["env"] as? [String: String], ["FIGMA_TOKEN": "t", "FIGMA_TEAM": "42"])
    }

    func testLegacyRegistryAndKeychainValue() throws {
        let json =
            #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"gh","transport":"stdio","command":"npx","args":[],"url":"","secretKey":"GITHUB_TOKEN","agents":["codex"],"appliedAgents":[]}"#
        let legacy = try JSONDecoder().decode(MCPServer.self, from: Data(json.utf8))
        XCTAssertEqual(legacy.keys, ["GITHUB_TOKEN"])
        XCTAssertEqual(ServerKeyStore.decode("raw-token", keys: legacy.keys), ["GITHUB_TOKEN": "raw-token"])
        XCTAssertEqual(ServerKeyStore.decode(#"{"A":"1","B":"2"}"#, keys: ["A", "B"]), ["A": "1", "B": "2"])

        let roundTrip = try JSONDecoder().decode(MCPServer.self, from: JSONEncoder().encode(server))
        XCTAssertEqual(roundTrip, server)
    }

    func testKeyValidation() {
        XCTAssertTrue(MCPServer.isValidKey("X-Api-Key"))
        XCTAssertFalse(MCPServer.isValidKey("A B"))
        XCTAssertFalse(MCPServer.isValidKey("A=B"))
        XCTAssertFalse(MCPServer.isValidKey("Auth:"))
    }
}

final class ImportTests: XCTestCase {
    func testReadsCodexServers() {
        let text = """
            model = "gpt-5"

            [mcp_servers.gl]
            url = "https://gl.example/mcp" # comment
            bearer_token_env_var = "GL"

            [mcp_servers.gl.http_headers]
            "Private-Token" = "t"

            [mcp_servers.gl.tools.x]
            approval_mode = "approve"

            [mcp_servers.sentry]
            command = "npx"
            args = [
              "-y",
              'pkg@1, 2',
            ]
            startup_timeout_sec = 60.0
            env = { SENTRY_HOST = "h", "A-B" = "a\\"b" }

            [mcp_servers.broken]
            startup_timeout_sec = 1
            """
        let servers = CodexTOML.readServers(in: text)
        XCTAssertEqual(servers.map(\.server.name), ["gl", "sentry"])
        XCTAssertEqual(servers[0].server.transport, .http)
        XCTAssertEqual(servers[0].server.url, "https://gl.example/mcp")
        XCTAssertEqual(servers[0].values, ["Private-Token": "t"])
        XCTAssertEqual(servers[1].server.command, "npx")
        XCTAssertEqual(servers[1].server.args, ["-y", "pkg@1, 2"])
        XCTAssertEqual(servers[1].values, ["SENTRY_HOST": "h", "A-B": "a\"b"])
        XCTAssertEqual(servers[1].server.keys, ["A-B", "SENTRY_HOST"])
    }

    func testReadsJSONServersAndSkipsSSE() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = home.appendingPathComponent(".gemini/config/mcp_config.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(
            #"{"mcpServers":{"a":{"command":"x","args":["1"],"env":{"K":"v"}},"b":{"serverUrl":"https://b/mcp","headers":{"H":"h"}},"c":{"type":"sse","url":"https://c"}}}"#
                .utf8
        ).write(to: file)
        defer { try? FileManager.default.removeItem(at: home) }

        let servers = try AntigravityAdapter(runner: CommandRunner(home: home, searchPath: [])).readServers()
        XCTAssertEqual(servers.map(\.server.name), ["a", "b"])
        XCTAssertEqual(servers[0].values, ["K": "v"])
        XCTAssertEqual(servers[1].server.url, "https://b/mcp")
        XCTAssertEqual(servers[1].values, ["H": "h"])
    }

    func testCandidatesMergeEqualDefinitionsAndKeepVariants() {
        func stdio(_ name: String, _ arg: String) -> FoundServer {
            FoundServer(server: MCPServer(name: name, transport: .stdio, command: "npx", args: [arg]), values: [:])
        }
        let candidates = ServerImport.candidates(
            found: [
                (.codex, [stdio("figma", "a"), stdio("mine", "x")]),
                (.cursor, [stdio("figma", "b")]),
                (.claudeDesktop, [stdio("figma", "b"), stdio("bad name", "x")]),
            ], existingNames: ["mine"])

        XCTAssertEqual(candidates.map(\.name), ["figma"])
        let figma = candidates[0]
        XCTAssertEqual(figma.variants.map(\.agents), [[.codex], [.cursor, .claudeDesktop]])
        XCTAssertEqual(figma.suggestedVariant, 1)
        let (server, _) = figma.server(variant: 1)
        XCTAssertEqual(server.agents, [.cursor, .claudeDesktop])
        XCTAssertEqual(server.appliedAgents, [.cursor, .claudeDesktop])
    }

    func testFlagsSecretsInArguments() {
        let found = FoundServer(
            server: MCPServer(
                name: "f", transport: .stdio, command: "npx",
                args: ["-y", "pkg", "--figma-api-key=abc", "--token", "t", "--stdio"]), values: [:])
        XCTAssertEqual(found.secretLikeArguments, ["--figma-api-key", "--token"])
    }

    func testDesktopWritesRemoteServersThroughMCPRemoteAndReadsThemBack() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"mcpServers":{"own":{"command":"npx","args":["mcp-remote","https://o","--header","A:${X}"],"env":{"X":"1"}}}}"#.utf8)
            .write(to: file)
        defer { try? FileManager.default.removeItem(at: home) }

        let adapter = ClaudeDesktopAdapter(runner: CommandRunner(home: home, searchPath: []))
        let server = MCPServer(name: "gl", transport: .http, url: "https://gl/mcp", keys: ["Private-Token"])
        try adapter.upsert(server, values: ["Private-Token": "glpat x"])

        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        let entry = (root["mcpServers"] as! [String: Any])["gl"] as! [String: Any]
        XCTAssertEqual(entry["command"] as? String, "npx")
        XCTAssertEqual(
            entry["args"] as? [String], ["-y", "mcp-remote", "https://gl/mcp", "--header", "Private-Token:${MCP_HEADER_PRIVATE_TOKEN}"])
        XCTAssertEqual(entry["env"] as? [String: String], ["MCP_HEADER_PRIVATE_TOKEN": "glpat x"])

        let read = try adapter.readServers()
        XCTAssertEqual(read.map(\.server.name), ["gl", "own"])
        XCTAssertEqual(read[0].server.transport, .http)
        XCTAssertEqual(read[0].values, ["Private-Token": "glpat x"])
        XCTAssertEqual(read[1].server.transport, .stdio)  // hand-made mcp-remote stays as it is
    }
}

final class ProjectScopeTests: XCTestCase {
    func testClaudeProjectServersFromLocalScopeAndMCPJSON() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = home.appendingPathComponent("work/app")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data(#"{"mcpServers":{"jira":{"type":"http","url":"https://j","headers":{"Authorization":"Token ${JIRA_PAT}"}}}}"#.utf8)
            .write(to: project.appendingPathComponent(".mcp.json"))
        let state = #"{"mcpServers":{},"projects":{"\#(project.path)":{"mcpServers":{"figma":{"command":"npx"}}},"/nowhere":{}}}"#
        try Data(state.utf8).write(to: home.appendingPathComponent(".claude.json"))
        defer { try? FileManager.default.removeItem(at: home) }

        let adapter = ClaudeAdapter(runner: CommandRunner(home: home, searchPath: []))
        XCTAssertEqual(adapter.projectServers(), ["jira": [project.path], "figma": [project.path]])
        XCTAssertEqual(try adapter.serverNames(), [])
    }
}

final class UsageTests: XCTestCase {
    func testClaudeLimitsList() throws {
        let json =
            try JSONSerialization.jsonObject(
                with: Data(
                    #"""
                    {"five_hour":{"utilization":14.0,"resets_at":"2026-11-12T00:09:59.560491+00:00"},
                     "limits":[{"kind":"session","percent":14,"resets_at":"2026-11-12T00:09:59.560491+00:00","scope":null},
                               {"kind":"weekly_all","percent":47,"resets_at":"2026-11-14T01:59:59.560514+00:00"},
                               {"kind":"weekly_scoped","percent":4,"resets_at":"2026-11-14T01:59:59Z","scope":{"model":{"display_name":"Fable"}}}]}
                    """#.utf8)) as! [String: Any]
        let windows = try UsageReader.claudeWindows(from: json)
        XCTAssertEqual(windows.map(\.label), ["5-hour session", "Week, all models", "Week, Fable"])
        XCTAssertEqual(windows.map(\.usedFraction), [0.14, 0.47, 0.04])
        XCTAssertEqual(windows[0].resetsAt, UsageReader.parseDate("2026-11-12T00:09:59.560Z"))
    }

    func testClaudeLegacyFields() throws {
        let json =
            try JSONSerialization.jsonObject(with: Data(#"{"five_hour":{"utilization":50,"resets_at":null},"seven_day":null}"#.utf8))
            as! [String: Any]
        XCTAssertEqual(try UsageReader.claudeWindows(from: json).map(\.label), ["5-hour session"])
        XCTAssertThrowsError(try UsageReader.claudeWindows(from: ["error": "x"]))
    }

    func testAntigravityQuotas() throws {
        let json =
            try JSONSerialization.jsonObject(
                with: Data(
                    #"""
                    {"models":{"claude-sonnet-4-6":{"displayName":"Claude Sonnet 4.6","quotaInfo":{"remainingFraction":0.25,"resetTime":"2026-11-18T20:16:35Z"}},
                               "gemini-3.8-flash-tiered":{"quotaInfo":{"resetTime":"2026-11-16T15:53:24Z"}},
                               "tab_x":{"quotaInfo":{"remainingFraction":1}},
                               "gemini-lite":{"displayName":"Lite","quotaInfo":{"remainingFraction":1}}},
                     "agentModelSorts":[{"groups":[{"modelIds":["claude-sonnet-4-6","missing"]}]}],
                     "tieredModelIds":{"pro":["gemini-3.8-flash-tiered"],"flash":["gemini-3.8-flash-tiered"],"flashLite":["gemini-lite"]}}
                    """#.utf8)) as! [String: Any]
        let windows = try UsageReader.antigravityWindows(from: json)
        XCTAssertEqual(windows.map(\.label), ["Claude Sonnet 4.6", "Gemini Pro / Flash", "Lite"])
        XCTAssertEqual(windows[0].usedFraction ?? -1, 0.75, accuracy: 0.0001)
        XCTAssertEqual(windows[1].usedFraction, 1)  // reset time without a fraction: used up
        XCTAssertEqual(windows[2].usedFraction, 0)
        XCTAssertNotNil(windows[0].resetsAt)
    }

    func testUntouchedAntigravityQuotaHasNoReset() throws {
        let json =
            try JSONSerialization.jsonObject(
                with: Data(
                    #"""
                    {"models":{"m":{"displayName":"M","quotaInfo":{"remainingFraction":1,"resetTime":"2026-11-19T15:13:17Z"}}},
                     "agentModelSorts":[{"groups":[{"modelIds":["m"]}]}]}
                    """#.utf8)) as! [String: Any]
        let window = try XCTUnwrap(UsageReader.antigravityWindows(from: json).first)
        XCTAssertEqual(window.usedFraction, 0)
        XCTAssertNil(window.resetsAt)
    }

    func testCodexTokensSinceStartOfDay() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func event(_ time: String, total: (Int, Int, Int), last: (Int, Int, Int)) -> String {
            #"{"timestamp":"\#(time)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(total.0),"cached_input_tokens":\#(total.1),"output_tokens":\#(total.2)},"last_token_usage":{"input_tokens":\#(last.0),"cached_input_tokens":\#(last.1),"output_tokens":\#(last.2)}},"rate_limits":null}}"#
        }
        // A thread from yesterday, continued today; the same event twice; then a resumed thread in a new file.
        try [
            event("2026-03-04T22:00:00Z", total: (1000, 800, 50), last: (1000, 800, 50)),
            event("2026-03-05T09:00:00Z", total: (1500, 1200, 80), last: (500, 400, 30)),
            event("2026-03-05T09:00:01Z", total: (1500, 1200, 80), last: (500, 400, 30)),
            #"{"timestamp":"2026-03-05T09:01:00Z","type":"event_msg","payload":{"type":"token_count","info":null}}"#,
        ].joined(separator: "\n").write(to: root.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
        try [
            event("2026-03-05T10:00:00Z", total: (9000, 8000, 900), last: (200, 100, 10)),
            event("2026-03-05T10:05:00Z", total: (9300, 8200, 920), last: (300, 200, 20)),
        ].joined(separator: "\n").write(to: root.appendingPathComponent("b.jsonl"), atomically: true, encoding: .utf8)

        let since = try XCTUnwrap(UsageReader.parseDate("2026-03-05T00:00:00Z"))
        let tokens = UsageReader.codexTokens(in: root, since: since)
        XCTAssertEqual([tokens.input, tokens.cachedInput, tokens.output], [500 + 200 + 300, 400 + 100 + 200, 30 + 10 + 20])
        XCTAssertEqual(tokens.total, 1060)
        XCTAssertEqual(tokens.freshInput, 300)
        XCTAssertEqual(tokens.hourly.count, 24)
        XCTAssertEqual(tokens.hourly.reduce(0, +), 1060)
    }

    func testCodexRateLimitsFromSessions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("2026/03/05")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: dir.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
        }
        let lines = [
            #"{"timestamp":"2026-03-05T12:00:00.000Z","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":10.0,"window_minutes":300,"resets_at":1772733506},"secondary":{"used_percent":3.0,"window_minutes":10080,"resets_at":1773320306},"plan_type":"plus"}}}"#,
            #"{"timestamp":"2026-03-05T12:59:12.716Z","payload":{"type":"token_count","rate_limits":null}}"#,
        ]
        try lines.joined(separator: "\n").write(to: dir.appendingPathComponent("rollout.jsonl"), atomically: true, encoding: .utf8)

        let latest = try XCTUnwrap(
            UsageReader.latestCodexRateLimits(in: dir.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()))
        XCTAssertEqual(latest.windows.map(\.label), ["5-hour window", "Week"])
        XCTAssertEqual(latest.windows.map(\.usedFraction), [0.1, 0.03])
        XCTAssertEqual(latest.plan, "plus")
        XCTAssertEqual(latest.at, UsageReader.parseDate("2026-03-05T12:00:00.000Z"))
    }

    func testParsesGoTimestampsWithNanoseconds() {
        let parsed = UsageReader.parseDate("2026-11-11T23:16:23.788785+02:00")?.timeIntervalSince1970 ?? 0
        let expected = UsageReader.parseDate("2026-11-11T21:16:23Z")?.timeIntervalSince1970 ?? -10
        XCTAssertEqual(parsed, expected, accuracy: 1)
    }
}

final class SecurityTests: XCTestCase {
    func testNewConfigFilesAreOwnerOnlyAndTokenWritesTightenAgentFiles() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let cursor = CursorAdapter(runner: CommandRunner(home: home, searchPath: []))
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".cursor"), withIntermediateDirectories: true)

        // A new file written by AgentHub is created private.
        try cursor.upsert(MCPServer(name: "a", transport: .stdio, command: "x"), values: [:])
        XCTAssertEqual(try mode(cursor.configURL), 0o600)

        // A world-readable file (as agent CLIs create them) is tightened once a token goes in.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: cursor.configURL.path)
        let sync = MCPSync(adapters: [cursor], snapshots: SnapshotStore(root: home.appendingPathComponent("snapshots")))
        let server = MCPServer(name: "b", transport: .stdio, command: "x", keys: ["T"], agents: [.cursor])
        XCTAssertEqual(sync.apply(server, values: ["T": "secret"]).outcomes[.cursor], .applied)
        XCTAssertEqual(try mode(cursor.configURL), 0o600)

        // Its snapshot (taken while it was still 0644) is private too, in a private folder.
        let snapshots = home.appendingPathComponent("snapshots")
        XCTAssertEqual(try mode(snapshots), 0o700)
        let session = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil).first)
        XCTAssertEqual(try mode(session.appendingPathComponent("cursor-mcp.json")), 0o600)
    }

    func testRegistryIsPrivate() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RegistryStore(url: dir.appendingPathComponent("registry.json"))
        try store.save([MCPServer(name: "a", transport: .stdio, command: "x", args: ["--token=t"])])
        XCTAssertEqual(try mode(store.url), 0o600)
        XCTAssertEqual(try mode(dir), 0o700)
    }

    func testLineBreaksInValuesNeverReachConfigs() {
        XCTAssertFalse(MCPServer.isValidValue("Bearer t\r\nX-Evil: 1"))
        let server = MCPServer(name: "s", transport: .http, url: "https://x", keys: ["Authorization"])
        XCTAssertEqual(
            ClaudeAdapter.addArguments(server, values: ["Authorization": "t\nX: y"]),
            ["mcp", "add", "-s", "user", "-t", "http", "s", "https://x"])
    }

    private func mode(_ url: URL) throws -> Int {
        try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! Int
    }
}

final class SessionTests: XCTestCase {
    func testClaudeSessionFile() {
        let waiting = SessionScanner.claudeSession(from: [
            "pid": 42, "cwd": "/w/app", "name": "fix-login", "status": "waiting",
            "waitingFor": "permission", "statusUpdatedAt": 1_794_435_501_000,
        ])
        XCTAssertEqual(waiting?.state, .waiting(reason: "permission"))
        XCTAssertEqual(waiting?.project, "app")
        XCTAssertEqual(waiting?.since, Date(timeIntervalSince1970: 1_794_435_501))
        XCTAssertEqual(SessionScanner.claudeSession(from: ["pid": 1, "status": "busy"])?.state, .working)
        XCTAssertEqual(SessionScanner.claudeSession(from: ["pid": 1, "status": "new-thing"])?.state, .running)
        XCTAssertNil(SessionScanner.claudeSession(from: ["status": "idle"]))
    }

    func testOnlyLiveClaudeSessionsAreListed() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dir = home.appendingPathComponent(".claude/sessions")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let me = ProcessInfo.processInfo.processIdentifier
        try Data(#"{"pid":\#(me),"status":"idle","cwd":"/x"}"#.utf8).write(to: dir.appendingPathComponent("\(me).json"))
        try Data(#"{"pid":999999,"status":"busy"}"#.utf8).write(to: dir.appendingPathComponent("999999.json"))
        XCTAssertEqual(SessionScanner(home: home).claudeSessions().map(\.pid), [me])
    }

    func testCodexTurnStateFromRolloutTail() {
        let started = #"{"type":"event_msg","payload":{"type":"task_started"}}"#
        let item = #"{"type":"response_item","payload":{"type":"reasoning"}}"#
        let done = #"{"type":"event_msg","payload":{"type":"task_complete"}}"#
        XCTAssertEqual(SessionScanner.codexState(fromTail: [done, started, item].joined(separator: "\n")), .working)
        XCTAssertEqual(SessionScanner.codexState(fromTail: [started, item, done].joined(separator: "\n")), .idle)
        XCTAssertEqual(SessionScanner.codexState(fromTail: item), .idle)
    }

    func testProcessTableSeesItself() {
        let me = ProcessInfo.processInfo.processIdentifier
        XCTAssertTrue(ProcessTable.isAlive(me))
        XCTAssertEqual(ProcessTable.ancestry(of: me).first, me)
        XCTAssertEqual(ProcessTable.workingDirectory(me), FileManager.default.currentDirectoryPath)
    }
}

final class AccountSwitchTests: XCTestCase {
    /// An in-memory slot standing in for an agent's Keychain item or file.
    final class MemorySlot: SignInSlot, @unchecked Sendable {
        var value: String?
        var agent: AgentID { .codex }
        func read() throws -> SignIn? { value.map { SignIn(raw: $0, email: $0.components(separatedBy: "|").first, authMethod: "test") } }
        func write(_ raw: String) throws { value = raw }
        func clear() throws { value = nil }
    }

    func testSwitchAddAndCancelKeepEverySignInSaved() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let service = "dev.agenthub.tests.\(UUID().uuidString)"
        let store = AccountVault(metadataURL: dir.appendingPathComponent("accounts.json"), keychain: KeychainStore(service: service))
        let slot = MemorySlot()
        let switcher = AccountSwitcher(slot: slot, vault: store)
        defer {
            for account in store.load() { store.keychain.delete(account.email) }
            try? FileManager.default.removeItem(at: dir)
        }

        slot.value = "a@x|token1"
        XCTAssertEqual(try switcher.captureCurrent()?.email, "a@x")

        // Adding: the current sign-in is saved first, then the slot is cleared for the new login.
        XCTAssertEqual(try switcher.beginAdding()?.email, "a@x")
        XCTAssertNil(slot.value)
        slot.value = "b@x|token2"  // the agent's own login wrote this
        try switcher.captureCurrent()
        XCTAssertEqual(store.load().map(\.email).sorted(), ["a@x", "b@x"])

        // The agent refreshed its token in place; switching away re-saves it before swapping.
        slot.value = "b@x|token2-refreshed"
        try switcher.switchTo("a@x")
        XCTAssertEqual(slot.value, "a@x|token1")
        XCTAssertEqual(store.savedSignIn(for: "b@x"), "b@x|token2-refreshed")
        XCTAssertThrowsError(try switcher.switchTo("nobody@x"))
        XCTAssertEqual(try mode(store.metadataURL), 0o600)
    }

    func testCodexAuthSlotIdentityAndPermissions() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let slot = CodexAuthSlot(home: home)
        XCTAssertNil(try slot.read())

        try slot.write(#"{"auth_mode":"apikey","OPENAI_API_KEY":"sk-proj-abcdWXYZ"}"#)
        XCTAssertEqual(try slot.read()?.email, "API key ••••WXYZ")
        XCTAssertEqual(try mode(slot.url), 0o600)

        // ChatGPT sign-in: the email comes from the id token's claims.
        let claims = Data(#"{"email":"me@example.com"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        try slot.write(#"{"auth_mode":"chatgpt","tokens":{"id_token":"h.\#(claims).s","access_token":"a"}}"#)
        XCTAssertEqual(try slot.read()?.email, "me@example.com")
        XCTAssertEqual(try slot.read()?.authMethod, "chatgpt")

        XCTAssertThrowsError(try slot.write("not json"))
        try slot.clear()
        XCTAssertNil(try slot.read())
    }

    private func mode(_ url: URL) throws -> Int {
        try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! Int
    }
}

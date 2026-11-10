import Foundation

public struct CommandError: LocalizedError {
    public let command: String
    public let status: Int32
    public let output: String

    public var errorDescription: String? {
        let output = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(command) failed (exit \(status))" + (output.isEmpty ? "" : ": \(output)")
    }
}

/// Runs agent CLIs. Also used as the "environment" adapters work in: `home` can point
/// at a temporary directory in tests so nothing touches real configs.
public struct CommandRunner: Sendable {
    public let home: URL
    public let searchPath: [String]

    public init(home: URL, searchPath: [String]) {
        self.home = home
        self.searchPath = searchPath
    }

    /// A GUI app starts with a minimal PATH, so CLIs installed via npm, Homebrew or their own
    /// installers are invisible without asking the login shell and checking the usual places.
    public static func detect(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> CommandRunner {
        var dirs: [String] = []
        if let path = try? runRaw("/bin/zsh", ["-lc", "print -r -- $PATH"], environment: nil) {
            dirs += path.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":").map(String.init)
        }
        dirs += [
            home.appendingPathComponent(".local/bin").path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            home.appendingPathComponent(".npm-global/bin").path,
            home.appendingPathComponent(".bun/bin").path,
            home.appendingPathComponent(".volta/bin").path,
            "/usr/bin",
            "/bin",
        ]
        var seen = Set<String>()
        return CommandRunner(home: home, searchPath: dirs.filter { seen.insert($0).inserted })
    }

    public func which(_ tool: String) -> URL? {
        for dir in searchPath {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(tool)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// Runs `tool` with `args`. Any of `secrets` found in the output is masked before it can reach an error message.
    @discardableResult
    public func run(_ tool: String, _ args: [String], secrets: [String] = []) throws -> String {
        guard let executable = which(tool) else { throw AgentError.toolNotFound(tool) }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPath.joined(separator: ":")
        environment["HOME"] = home.path
        do {
            return try Self.runRaw(executable.path, args, environment: environment)
        } catch let error as CommandError {
            // Arguments may carry the token, so only the tool and subcommand are named.
            var output = error.output
            for secret in secrets where !secret.isEmpty {
                output = output.replacingOccurrences(of: secret, with: "•••")
            }
            throw CommandError(command: ([tool] + args.prefix(2)).joined(separator: " "), status: error.status, output: output)
        }
    }

    /// `input` is written to stdin, which keeps secrets out of the process list.
    static func runRaw(_ executable: String, _ args: [String], environment: [String: String]?, input: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        if let environment { process.environment = environment }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let stdin = input.map { _ in Pipe() }
        process.standardInput = stdin ?? FileHandle.nullDevice
        try process.run()
        if let stdin, let input {
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw CommandError(command: executable, status: process.terminationStatus, output: output)
        }
        return output
    }
}

/// Splits a command line typed by the user into argv, honouring quotes and backslashes.
public enum CommandLineParser {
    public static func split(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var hasToken = false
        var quote: Character?
        var escaped = false
        for char in line {
            if escaped {
                current.append(char)
                escaped = false
            } else if char == "\\" && quote != "'" {
                escaped = true
                hasToken = true
            } else if let q = quote {
                if char == q { quote = nil } else { current.append(char) }
            } else if char == "\"" || char == "'" {
                quote = char
                hasToken = true
            } else if char.isWhitespace {
                if hasToken { result.append(current) }
                current = ""
                hasToken = false
            } else {
                current.append(char)
                hasToken = true
            }
        }
        if hasToken { result.append(current) }
        return result
    }

    public static func join(_ argv: [String]) -> String {
        argv.map { arg in
            if arg.isEmpty { return "''" }
            guard arg.contains(where: { $0.isWhitespace || "\"'\\".contains($0) }) else { return arg }
            return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }
}

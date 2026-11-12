import Darwin
import Foundation

public enum SessionState: Hashable, Sendable {
    /// The agent is producing a reply or running tools.
    case working
    /// The agent stopped and asks for something: a permission, an answer. `reason` is the agent's own word for it.
    case waiting(reason: String?)
    case idle
    /// Running, but the agent doesn't say what it's doing.
    case running
}

/// One running agent session: an interactive Claude Code, a Codex CLI, an agy.
public struct AgentSession: Identifiable, Hashable, Sendable {
    public var agent: AgentID
    public var pid: Int32
    public var cwd: String
    /// The session's own name when the agent keeps one (Claude Code does).
    public var name: String?
    public var state: SessionState
    /// When the current state began, when the agent says.
    public var since: Date?

    public var id: String { "\(agent.rawValue)-\(pid)" }
    public var project: String { cwd.isEmpty ? "" : (cwd as NSString).lastPathComponent }
    /// "project · session name", or just the project when the name adds nothing.
    public var title: String {
        guard let name, !name.isEmpty, name != project else { return project }
        return "\(project) · \(name)"
    }

    public init(agent: AgentID, pid: Int32, cwd: String, name: String? = nil, state: SessionState, since: Date? = nil) {
        self.agent = agent
        self.pid = pid
        self.cwd = cwd
        self.name = name
        self.state = state
        self.since = since
    }
}

/// Finds running sessions from what agents already write to disk and from the process table.
/// Nothing is installed into the agents: no hooks, no config changes.
public struct SessionScanner: Sendable {
    public let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }

    public func scan() -> [AgentSession] {
        let processes = ProcessTable.all()
        return claudeSessions() + codexSessions(processes) + agySessions(processes)
    }

    // MARK: Claude Code

    /// `~/.claude/sessions/<pid>.json`, kept by Claude Code itself: `status` is `busy`, `idle` or `waiting`
    /// (with `waitingFor`), plus `cwd`, `name` and `statusUpdatedAt`. Files of exited sessions stay behind,
    /// so the pid is checked.
    public func claudeSessions() -> [AgentSession] {
        let dir = home.appendingPathComponent(".claude/sessions")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            guard let data = FileManager.default.contents(atPath: file.path),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let session = Self.claudeSession(from: json),
                ProcessTable.isAlive(session.pid)
            else { return nil }
            return session
        }
        .sorted { $0.pid < $1.pid }
    }

    static func claudeSession(from json: [String: Any]) -> AgentSession? {
        guard let pid = (json["pid"] as? NSNumber)?.int32Value else { return nil }
        let state: SessionState
        switch json["status"] as? String {
        case "busy": state = .working
        case "waiting": state = .waiting(reason: json["waitingFor"] as? String)
        case "idle": state = .idle
        default: state = .running
        }
        let since = ((json["statusUpdatedAt"] ?? json["updatedAt"]) as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return AgentSession(
            agent: .claude, pid: pid, cwd: json["cwd"] as? String ?? "", name: json["name"] as? String, state: state, since: since)
    }

    // MARK: Codex

    /// Codex CLI processes; background `app-server` / `mcp-server` processes (IDE integrations) are not sessions.
    /// State comes from the session's rollout file: a `task_started` without a later `task_complete` is a turn in progress.
    public func codexSessions(_ processes: [ProcessTable.Entry]) -> [AgentSession] {
        let candidates = processes.filter {
            $0.name == "codex" && !$0.arguments.contains(where: { ["app-server", "mcp-server"].contains($0) })
        }
        guard !candidates.isEmpty else { return [] }
        let rollouts = recentCodexRollouts()
        return candidates.map { process in
            let cwd = ProcessTable.workingDirectory(process.pid) ?? ""
            let rollout = rollouts.first { $0.cwd == cwd && $0.modified >= process.started.addingTimeInterval(-5) }
            let state = rollout.map { Self.codexState(fromTail: $0.tail) } ?? .idle
            return AgentSession(agent: .codex, pid: process.pid, cwd: cwd, state: state, since: rollout?.modified)
        }
    }

    struct Rollout {
        var cwd: String
        var modified: Date
        var tail: String
    }

    /// Rollout files touched in the last two days, newest first, with their `session_meta` cwd and last 64 KB.
    func recentCodexRollouts() -> [Rollout] {
        let root = home.appendingPathComponent(".codex/sessions")
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return []
        }
        let cutoff = Date().addingTimeInterval(-2 * 86_400)
        var files: [(URL, Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modified > cutoff { files.append((url, modified)) }
        }
        return files.sorted { $0.1 > $1.1 }.compactMap { url, modified in
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            let head = String(decoding: handle.readData(ofLength: 16_384), as: UTF8.self)
            guard let firstLine = head.split(separator: "\n").first,
                let meta = try? JSONSerialization.jsonObject(with: Data(firstLine.utf8)) as? [String: Any],
                let cwd = (meta["payload"] as? [String: Any])?["cwd"] as? String
            else { return nil }
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
            let tail = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
            return Rollout(cwd: cwd, modified: modified, tail: tail)
        }
    }

    static func codexState(fromTail tail: String) -> SessionState {
        for line in tail.split(separator: "\n").reversed() {
            if line.contains("\"task_complete\"") { return .idle }
            if line.contains("\"task_started\"") { return .working }
        }
        return .idle
    }

    // MARK: Antigravity

    /// agy processes; `agy acp` runs inside an IDE and isn't a session of its own.
    public func agySessions(_ processes: [ProcessTable.Entry]) -> [AgentSession] {
        processes.filter { $0.name == "agy" && !$0.arguments.contains("acp") }.map { process in
            AgentSession(
                agent: .antigravity, pid: process.pid, cwd: ProcessTable.workingDirectory(process.pid) ?? "", state: .running,
                since: process.started)
        }
    }
}

/// The process table through libproc and sysctl, without spawning `ps` or `lsof`.
/// Only the user's own processes reveal their working directory and arguments, which is all AgentHub needs.
public enum ProcessTable {
    public struct Entry: Sendable {
        public var pid: Int32
        public var parent: Int32
        /// Executable name, e.g. `codex`.
        public var name: String
        /// argv without the executable.
        public var arguments: [String]
        public var started: Date
    }

    public static func all() -> [Entry] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        return pids.prefix(Int(max(filled, 0))).compactMap { pid in
            guard pid > 0, let info = bsdInfo(pid) else { return nil }
            let name = withUnsafeBytes(of: info.pbi_comm) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let started = Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
            let isAgent = ["claude", "codex", "agy"].contains(name)
            return Entry(
                pid: pid, parent: Int32(info.pbi_ppid), name: name,
                arguments: isAgent ? arguments(pid) : [], started: started)
        }
    }

    public static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    public static func parent(of pid: Int32) -> Int32? {
        bsdInfo(pid).map { Int32($0.pbi_ppid) }
    }

    /// `pid` and its ancestors up to launchd, nearest first.
    public static func ancestry(of pid: Int32) -> [Int32] {
        var chain: [Int32] = []
        var current: Int32? = pid
        while let pid = current, pid > 1, !chain.contains(pid), chain.count < 64 {
            chain.append(pid)
            current = parent(of: pid)
        }
        return chain
    }

    public static func workingDirectory(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        return path.isEmpty ? nil : path
    }

    private static func bsdInfo(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    /// argv from `KERN_PROCARGS2`: argc, the executable path, padding, then argc NUL-terminated strings.
    static func arguments(_ pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size && buffer[index] != 0 { index += 1 }  // executable path
        while index < size && buffer[index] == 0 { index += 1 }  // padding
        var args: [String] = []
        while index < size && args.count < Int(argc) {
            let start = index
            while index < size && buffer[index] != 0 { index += 1 }
            args.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return Array(args.dropFirst())
    }
}

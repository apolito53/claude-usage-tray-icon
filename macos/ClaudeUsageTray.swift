import AppKit
import CoreFoundation
import Darwin
import Foundation
import Security

private let appID = "claude-usage-tray"
private let appName = "Claude Usage Tray"
private let appVersion = "0.2.1"
private let usageEndpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
private let oauthBeta = "oauth-2025-04-20"
private let keychainService = "Claude Code-credentials"
private let responseTimeout: TimeInterval = 12
// Upper bound on the child Keychain read (see runCredentialEmit). This is
// generous on purpose: the first read after an install shows a macOS approval
// dialog, and the clock runs while the user decides. Measured locally, the
// first run took ~8.5s and the second ~6.9s before settling at ~0.09s, so a
// tight timeout kills exactly the run the user is watching. The credential
// load happens off the main thread, so waiting here never freezes the menu.
private let credentialScanTimeout: TimeInterval = 90
private let maximumResponseBytes = 256 * 1024
private let defaultRefreshInterval: TimeInterval = 5 * 60
private let offlineRetryIntervals: [TimeInterval] = [60, 2 * 60, 5 * 60]
private let rateLimitRetryIntervals: [TimeInterval] = [10 * 60, 30 * 60, 60 * 60]

// Our own path, used to re-launch this binary in credential-scan child mode.
private let currentExecutableURL: URL = {
    if let bundled = Bundle.main.executableURL {
        return bundled.standardizedFileURL.resolvingSymlinksInPath()
    }
    return URL(fileURLWithPath: CommandLine.arguments[0])
        .standardizedFileURL
        .resolvingSymlinksInPath()
}()

private let windowLabels: [(String, String)] = [
    ("five_hour", "Current session (5 hours)"),
    ("seven_day", "Current week (all models)"),
    ("seven_day_opus", "Current week (Opus)"),
    ("seven_day_sonnet", "Current week (Sonnet)"),
    ("seven_day_overage_included", "Current week (overage included)"),
]

private enum UsageError: LocalizedError {
    case message(String)
    case credential(String)
    case rateLimited(Int?)

    var errorDescription: String? {
        switch self {
        case .message(let message):
            return message
        case .credential(let message):
            return message
        case .rateLimited:
            return "Claude temporarily rate-limited usage checks."
        }
    }
}

private struct UsageWindow {
    let key: String
    let label: String
    let usedPercent: Int
    let remainingPercent: Int
    let resetAt: Date?
}

private struct UsageSnapshot {
    let windows: [UsageWindow]
    let checkedAt: Date

    func window(_ key: String) -> UsageWindow? {
        windows.first { $0.key == key }
    }

    var primary: UsageWindow {
        window("five_hour") ?? windows[0]
    }
}

private enum UsageParser {
    private static let fractionalDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ data: Data) throws -> UsageSnapshot {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw UsageError.message("Claude returned an unreadable usage response.")
        }
        guard let document = value as? [String: Any] else {
            throw UsageError.message("Claude returned an unexpected usage response.")
        }

        var windows: [UsageWindow] = []
        for (key, label) in windowLabels {
            guard let rawValue = document[key], !(rawValue is NSNull) else {
                continue
            }
            guard let raw = rawValue as? [String: Any] else {
                throw UsageError.message(
                    "Claude usage window '\(key)' had an unexpected shape."
                )
            }
            let utilization = raw["utilization"] ?? raw["used_percentage"]
            let usedPercent = try percentage(utilization, key: key)
            windows.append(
                UsageWindow(
                    key: key,
                    label: label,
                    usedPercent: usedPercent,
                    remainingPercent: 100 - usedPercent,
                    resetAt: parseDate(raw["resets_at"])
                )
            )
        }

        guard !windows.isEmpty else {
            throw UsageError.message(
                "Claude returned no active subscription usage windows. This login may not have a Pro, Max, Team, or Enterprise quota."
            )
        }
        return UsageSnapshot(windows: windows, checkedAt: Date())
    }

    private static func percentage(_ value: Any?, key: String) throws -> Int {
        guard
            let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID(),
            number.doubleValue.isFinite
        else {
            throw UsageError.message(
                "Claude usage window '\(key)' omitted utilization."
            )
        }
        return max(0, min(100, Int(number.doubleValue.rounded())))
    }

    private static func parseDate(_ value: Any?) -> Date? {
        if let number = value as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID() {
            return Date(timeIntervalSince1970: number.doubleValue)
        }
        guard let string = value as? String, !string.isEmpty else {
            return nil
        }
        return fractionalDateFormatter.date(from: string)
            ?? dateFormatter.date(from: string)
    }
}

private struct LoadedCredential {
    let token: String
    let keychainServiceName: String?
}

private struct KeychainCandidate {
    let serviceName: String
    let modifiedAt: Date
}

/// Recognizes the legacy `Claude Code-credentials` item and the current
/// `Claude Code-credentials-<8 hex>` variants Claude Code rewrites on refresh.
/// File scope because both the parent and the child scan need it.
private func isClaudeCredentialService(_ serviceName: String) -> Bool {
    if serviceName == keychainService {
        return true
    }
    let prefix = "\(keychainService)-"
    guard serviceName.hasPrefix(prefix) else {
        return false
    }
    let suffix = serviceName.dropFirst(prefix.count)
    let hexadecimal = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
    return suffix.count == 8
        && suffix.unicodeScalars.allSatisfy { hexadecimal.contains($0) }
}

/// Extracts `claudeAiOauth.accessToken` from a Claude credential blob.
/// Pure JSON handling -- no Security calls -- so both the parent (for the
/// credential-file path) and the child (for the Keychain path) can use it.
private func accessToken(from data: Data) throws -> String {
    guard
        let object = try? JSONSerialization.jsonObject(with: data),
        let document = object as? [String: Any],
        let oauth = document["claudeAiOauth"] as? [String: Any],
        let token = oauth["accessToken"] as? String,
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
        throw UsageError.credential(
            "Claude Code is not signed in with Claude.ai subscription OAuth. API, Bedrock, Vertex, and Foundry authentication do not expose subscription quota."
        )
    }
    return token.trimmingCharacters(in: .whitespacesAndNewlines)
}

private final class CredentialStore {
    private let lock = NSLock()
    private var cachedCredential: LoadedCredential?
    private var rejectedKeychainServices: Set<String> = []

    func token() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        if let cachedCredential = cachedCredential {
            return cachedCredential.token
        }
        let loaded = try loadCredential()
        cachedCredential = loaded
        return loaded.token
    }

    func invalidate() {
        lock.lock()
        if let serviceName = cachedCredential?.keychainServiceName {
            rejectedKeychainServices.insert(serviceName)
        }
        cachedCredential = nil
        lock.unlock()
    }

    private func loadCredential() throws -> LoadedCredential {
        let environment = ProcessInfo.processInfo.environment
        if let supplied = environment["CLAUDE_CODE_OAUTH_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !supplied.isEmpty {
            return LoadedCredential(token: supplied, keychainServiceName: nil)
        }

        if let configured = environment["CLAUDE_CONFIG_DIR"], !configured.isEmpty {
            let configuredURL = URL(fileURLWithPath: configured, isDirectory: true)
                .appendingPathComponent(".credentials.json")
            if FileManager.default.fileExists(atPath: configuredURL.path) {
                return LoadedCredential(
                    token: try tokenFromCredentialFile(configuredURL),
                    keychainServiceName: nil
                )
            }
        }

        var keychainFailure: String?
        do {
            return try credentialFromKeychain()
        } catch {
            keychainFailure = error.localizedDescription
        }

        let fallbackURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent(".credentials.json")
        if FileManager.default.fileExists(atPath: fallbackURL.path) {
            return LoadedCredential(
                token: try tokenFromCredentialFile(fallbackURL),
                keychainServiceName: nil
            )
        }

        throw UsageError.credential(
            keychainFailure
                ?? "No Claude.ai OAuth credentials were found. Sign Claude Code in with an eligible Claude.ai subscription."
        )
    }

    /// Ask a short-lived child process for a usable Claude OAuth credential.
    ///
    /// Every Security-framework call this app makes now happens in that child;
    /// see `runCredentialEmit(rejecting:)` for why. Only the chosen service
    /// name and its access token cross the pipe, and neither is ever logged.
    private func credentialFromKeychain() throws -> LoadedCredential {
        var arguments = ["--emit-credential"]
        // Services that already answered with a token Claude rejected (HTTP
        // 401) are skipped, preserving the pre-0.2.1 retry behavior.
        for rejected in rejectedKeychainServices.sorted() {
            arguments.append("--reject")
            arguments.append(rejected)
        }

        let process = Process()
        process.executableURL = currentExecutableURL
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw UsageError.credential(
                "Could not start the Claude credential reader: \(error.localizedDescription)"
            )
        }

        // A child stuck on a Keychain approval prompt must not hang a refresh.
        let watchdog = DispatchWorkItem { [weak process] in
            if process?.isRunning == true {
                process?.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(
            deadline: .now() + credentialScanTimeout,
            execute: watchdog
        )
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        guard process.terminationStatus == 0,
              let text = String(data: output, encoding: .utf8)
        else {
            throw UsageError.credential(
                "The Claude credential reader did not finish. Open Claude Code and run `/login`, then select Refresh now."
            )
        }

        // Wire format: "OK\t<service>\t<token>" or "ERR\t<message>".
        let fields = text.trimmingCharacters(in: .newlines).split(
            separator: "\t",
            maxSplits: 2,
            omittingEmptySubsequences: false
        )
        if fields.first == "OK", fields.count == 3 {
            let serviceName = String(fields[1])
            let token = String(fields[2]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard isClaudeCredentialService(serviceName), !token.isEmpty else {
                throw UsageError.credential(
                    "The Claude credential reader returned an unexpected result."
                )
            }
            return LoadedCredential(token: token, keychainServiceName: serviceName)
        }
        if fields.first == "ERR", fields.count >= 2 {
            throw UsageError.credential(String(fields[1]))
        }
        throw UsageError.credential(
            "The Claude credential reader returned an unexpected result."
        )
    }


    private func tokenFromCredentialFile(_ url: URL) throws -> String {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let permissions = attributes[.posixPermissions] as? NSNumber,
               permissions.intValue & 0o077 != 0 {
                throw UsageError.credential(
                    "Claude credential file permissions are too broad at \(url.path). Expected mode 0600."
                )
            }
            return try accessToken(from: Data(contentsOf: url))
        } catch let error as UsageError {
            throw error
        } catch {
            throw UsageError.credential(
                "Could not read Claude's credential file: \(error.localizedDescription)"
            )
        }
    }

}

private final class UsageClient {
    private let credentials = CredentialStore()
    private let session: URLSession
    private let taskLock = NSLock()
    private var task: URLSessionDataTask?

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = responseTimeout
        configuration.timeoutIntervalForResource = responseTimeout
        session = URLSession(configuration: configuration)
    }

    /// Loads the credential and issues the request.
    ///
    /// The credential load spawns a child process and can sit behind a macOS
    /// Keychain approval dialog, so it must not run on the main thread -- doing
    /// so froze the menu bar for as long as the dialog was up. `completion` may
    /// therefore be called on a background queue; callers hop to main.
    func getUsage(completion: @escaping (Result<UsageSnapshot, Error>) -> Void) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.performRequest(completion: completion)
        }
    }

    private func performRequest(completion: @escaping (Result<UsageSnapshot, Error>) -> Void) {
        let token: String
        do {
            token = try credentials.token()
        } catch {
            completion(.failure(error))
            return
        }

        var request = URLRequest(url: usageEndpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = responseTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(oauthBeta, forHTTPHeaderField: "anthropic-beta")
        request.setValue("\(appID)/\(appVersion)", forHTTPHeaderField: "User-Agent")

        let dataTask = session.dataTask(with: request) { [weak self] data, response, error in
            if let error = error as? URLError, error.code == .cancelled {
                return
            }
            if let error = error {
                completion(
                    .failure(
                        UsageError.message(
                            "Could not reach Claude's usage service: \(error.localizedDescription)"
                        )
                    )
                )
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(
                    .failure(
                        UsageError.message("Claude returned an unexpected HTTP response.")
                    )
                )
                return
            }
            if http.statusCode == 401 {
                self?.credentials.invalidate()
                completion(
                    .failure(
                        UsageError.credential(
                            "Claude rejected the saved OAuth token. Open Claude Code and run `/login`, then retry."
                        )
                    )
                )
                return
            }
            if http.statusCode == 403 {
                completion(
                    .failure(
                        UsageError.credential(
                            "This Claude login is not allowed to read subscription usage."
                        )
                    )
                )
                return
            }
            if http.statusCode == 429 {
                completion(
                    .failure(
                        UsageError.rateLimited(
                            Self.retryAfterSeconds(
                                http.value(forHTTPHeaderField: "Retry-After")
                            )
                        )
                    )
                )
                return
            }
            guard (200 ... 299).contains(http.statusCode) else {
                completion(
                    .failure(
                        UsageError.message(
                            "Claude usage request failed with HTTP \(http.statusCode)."
                        )
                    )
                )
                return
            }
            guard let data = data, data.count <= maximumResponseBytes else {
                completion(
                    .failure(
                        UsageError.message(
                            "Claude's usage response was missing or unexpectedly large."
                        )
                    )
                )
                return
            }
            do {
                completion(.success(try UsageParser.parse(data)))
            } catch {
                completion(.failure(error))
            }
        }
        taskLock.lock()
        task = dataTask
        taskLock.unlock()
        dataTask.resume()
    }

    func cancel() {
        taskLock.lock()
        let inFlight = task
        task = nil
        taskLock.unlock()
        inFlight?.cancel()
    }

    private static func retryAfterSeconds(_ value: String?) -> Int? {
        guard let value = value, !value.isEmpty else {
            return nil
        }
        if let seconds = Double(value) {
            return max(0, Int(seconds))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        guard let retryAt = formatter.date(from: value) else {
            return nil
        }
        return max(0, Int(retryAt.timeIntervalSinceNow))
    }
}

private final class FileLogger {
    private let lock = NSLock()
    let directoryURL: URL
    private let fileURL: URL
    private let oldFileURL: URL

    init() {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ClaudeUsageTray", isDirectory: true)
        directoryURL = directory
        fileURL = directory.appendingPathComponent("usage-tray.log")
        oldFileURL = directory.appendingPathComponent("usage-tray.log.1")
        try? FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        ensureLogFile()
    }

    func info(_ message: String) {
        write(level: "INFO", message: message)
    }

    func error(_ message: String) {
        write(level: "ERROR", message: message)
    }

    private func write(level: String, message: String) {
        lock.lock()
        defer { lock.unlock() }
        rotateIfNeeded()
        ensureLogFile()
        let timestamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(timestamp) [\(level)] \(message)\n".data(using: .utf8),
              let handle = try? FileHandle(forWritingTo: fileURL) else {
            return
        }
        handle.seekToEndOfFile()
        handle.write(data)
        handle.closeFile()
    }

    private func ensureLogFile() {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(
                atPath: fileURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        }
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    private func rotateIfNeeded() {
        guard
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: fileURL.path
            ),
            let size = attributes[.size] as? NSNumber,
            size.intValue >= 1024 * 1024
        else {
            return
        }
        try? FileManager.default.removeItem(at: oldFileURL)
        try? FileManager.default.moveItem(at: fileURL, to: oldFileURL)
    }
}

private final class SingleInstanceLock {
    private let descriptor: Int32
    private let path: String

    init?() {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/ClaudeUsageTray", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        path = directory.appendingPathComponent("claude-usage-tray.pid").path
        descriptor = Darwin.open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            return nil
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        ftruncate(descriptor, 0)
        let bytes = Array("\(getpid())\n".utf8)
        bytes.withUnsafeBytes { buffer in
            _ = Darwin.write(descriptor, buffer.baseAddress, buffer.count)
        }
    }

    deinit {
        unlink(path)
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}

private enum LaunchAgentManager {
    static let label = "com.apolito.claude-usage-tray"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func setEnabled(_ enabled: Bool, executableURL: URL) throws {
        if !enabled {
            if FileManager.default.fileExists(atPath: plistURL.path) {
                try FileManager.default.removeItem(at: plistURL)
            }
            return
        }
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        let executable = xmlEscape(executableURL.path)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>\(label)</string>
          <key>ProgramArguments</key>
          <array><string>\(executable)</string></array>
          <key>RunAtLoad</key>
          <true/>
          <key>ProcessType</key>
          <string>Interactive</string>
          <key>LimitLoadToSessionType</key>
          <string>Aqua</string>
        </dict>
        </plist>
        """
        try Data(plist.utf8).write(to: plistURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: plistURL.path
        )
    }

    private static func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

/// Compact time left until `date`, sized for the menu bar: "2h14m", "47m",
/// "<1m". Returns nil when there is no reset time to count down to.
///
/// Past the reset the window has already rolled over but our cached
/// percentage has not caught up yet, so this reports "now" rather than a
/// negative value; the next poll corrects the number.
private func formatRemaining(until date: Date?, from now: Date = Date()) -> String? {
    guard let date = date else {
        return nil
    }
    let seconds = date.timeIntervalSince(now)
    if seconds <= 0 {
        return "now"
    }
    let totalMinutes = Int(seconds / 60)
    if totalMinutes < 1 {
        return "<1m"
    }
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    return hours > 0 ? "\(hours)h\(minutes)m" : "\(minutes)m"
}

/// Longer form for the menu, where there is room: "2 hours 14 minutes".
private func formatRemainingLong(until date: Date?, from now: Date = Date()) -> String? {
    guard let date = date else {
        return nil
    }
    let seconds = date.timeIntervalSince(now)
    if seconds <= 0 {
        return "now"
    }
    let totalMinutes = max(1, Int(seconds / 60))
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    var parts: [String] = []
    if hours > 0 {
        parts.append("\(hours) hour" + (hours == 1 ? "" : "s"))
    }
    if minutes > 0 {
        parts.append("\(minutes) minute" + (minutes == 1 ? "" : "s"))
    }
    return parts.joined(separator: " ")
}

/// Status-item image: a ring holding the percentage, optionally followed by the
/// countdown. `detail` is drawn to the right of the ring, so the image -- and
/// therefore the menu-bar item -- grows only when there is a countdown to show.
private func statusImage(text: String, detail: String?, offline: Bool) -> NSImage {
    let ringWidth: CGFloat = 28
    let detailFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
    var detailWidth: CGFloat = 0
    if let detail = detail, !detail.isEmpty {
        detailWidth = ceil(
            NSString(string: detail).size(withAttributes: [.font: detailFont]).width
        ) + 3
    }
    let size = NSSize(width: ringWidth + detailWidth, height: 18)
    let image = NSImage(size: size, flipped: false) { _ in
        NSColor.black.setStroke()
        let circle = NSBezierPath(ovalIn: NSRect(x: 5, y: 1, width: 16, height: 16))
        circle.lineWidth = 1.35
        circle.stroke()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let fontSize: CGFloat = text.count >= 3 ? 6.8 : (text.count == 2 ? 8.5 : 10)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph,
        ]
        NSString(string: text).draw(
            in: NSRect(x: 5, y: 4.2, width: 16, height: 10),
            withAttributes: attributes
        )
        if offline {
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: 20, y: 11.5, width: 5, height: 5)).fill()
        }
        if let detail = detail, !detail.isEmpty {
            let detailStyle = NSMutableParagraphStyle()
            detailStyle.alignment = .left
            NSString(string: detail).draw(
                in: NSRect(x: ringWidth, y: 3.4, width: detailWidth, height: 12),
                withAttributes: [
                    .font: detailFont,
                    .foregroundColor: NSColor.black,
                    .paragraphStyle: detailStyle,
                ]
            )
        }
        return true
    }
    // Template so the whole item follows the system menu-bar tint.
    image.isTemplate = true
    return image
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let executableURL: URL
    private let client = UsageClient()
    private let logger = FileLogger()
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var summaryItem: NSMenuItem!
    private var sessionResetItem: NSMenuItem!
    private var connectionItem: NSMenuItem!
    private var refreshItem: NSMenuItem!
    private var startAtLoginItem: NSMenuItem!
    private var timer: Timer?
    // Redraws the countdown between polls; see redrawCountdown().
    private var displayTimer: Timer?
    private var latestSnapshot: UsageSnapshot?
    private var refreshInProgress = false
    private var consecutiveFailures = 0
    private var credentialFailures = 0
    private var rateLimitFailures = 0

    init(executableURL: URL) {
        self.executableURL = executableURL
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureMenu()
        logger.info("\(appName) \(appVersion) starting on macOS.")
        refresh()
        startCountdownTimer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        displayTimer?.invalidate()
        client.cancel()
        logger.info("\(appName) exiting.")
    }

    private func configureMenu() {
        // Variable length: the item widens only when a countdown is shown.
        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )
        statusItem.button?.image = statusImage(text: "?", detail: nil, offline: false)
        statusItem.button?.toolTip = "Claude usage loading"
        statusItem.button?.setAccessibilityLabel("Claude usage loading")

        menu = NSMenu()
        menu.autoenablesItems = false
        // Scope: this app reports the rolling five-hour session window only.
        // The weekly and per-model entries were removed deliberately; the
        // parser still reads them so `--check` stays useful for diagnostics.
        summaryItem = disabledItem("Claude usage: loading…")
        sessionResetItem = disabledItem("Session reset: loading…")
        connectionItem = disabledItem("Connection: loading…")
        let informationItems: [NSMenuItem] = [
            summaryItem,
            sessionResetItem,
            connectionItem,
        ]
        for item in informationItems {
            menu.addItem(item)
        }
        menu.addItem(.separator())

        refreshItem = NSMenuItem(
            title: "Refresh now",
            action: #selector(refreshAction),
            keyEquivalent: "r"
        )
        refreshItem.target = self
        menu.addItem(refreshItem)

        startAtLoginItem = NSMenuItem(
            title: "Start at login",
            action: #selector(toggleStartAtLogin),
            keyEquivalent: ""
        )
        startAtLoginItem.target = self
        startAtLoginItem.state = LaunchAgentManager.isEnabled ? .on : .off
        menu.addItem(startAtLoginItem)

        let logsItem = NSMenuItem(
            title: "Open diagnostic logs",
            action: #selector(openLogs),
            keyEquivalent: ""
        )
        logsItem.target = self
        menu.addItem(logsItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func refreshAction() {
        refresh()
    }

    private func refresh() {
        guard !refreshInProgress else {
            return
        }
        refreshInProgress = true
        refreshItem.isEnabled = false
        if latestSnapshot == nil {
            summaryItem.title = "Claude usage: refreshing…"
            connectionItem.title = "Connecting…"
        } else {
            connectionItem.title = "Checking connection…"
        }

        client.getUsage { [weak self] result in
            DispatchQueue.main.async {
                self?.finishRefresh(result)
            }
        }
    }

    private func finishRefresh(_ result: Result<UsageSnapshot, Error>) {
        refreshInProgress = false
        refreshItem.isEnabled = true
        switch result {
        case .success(let snapshot):
            latestSnapshot = snapshot
            consecutiveFailures = 0
            credentialFailures = 0
            rateLimitFailures = 0
            apply(snapshot)
            logger.info(
                "Usage refreshed: "
                    + snapshot.windows
                        .map { "\($0.key)=\($0.usedPercent)% used" }
                        .joined(separator: ", ")
                    + "."
            )
            schedule(after: configuredRefreshInterval())
        case .failure(let error):
            consecutiveFailures += 1
            apply(error)
            logger.error("Usage refresh failed: \(error.localizedDescription)")
            schedule(after: retryDelay(for: error))
        }
    }

    private func apply(_ snapshot: UsageSnapshot) {
        let session = snapshot.window("five_hour") ?? snapshot.primary
        summaryItem.title = format(session)
        sessionResetItem.title = sessionResetTitle(for: session)
        connectionItem.title = "Online - updated \(timeFormatter.string(from: snapshot.checkedAt))"
        updateStatusImage(
            text: String(session.remainingPercent),
            detail: formatRemaining(until: session.resetAt),
            offline: false
        )
    }

    /// "Session resets in 2 hours 14 minutes - Mon, Sep 1 at 7:29 PM"
    private func sessionResetTitle(for window: UsageWindow) -> String {
        guard let resetAt = window.resetAt else {
            return "Session reset time unavailable"
        }
        guard let remaining = formatRemainingLong(until: resetAt) else {
            return formatReset("Session resets", resetAt)
        }
        if remaining == "now" {
            return "Session resetting now - \(resetFormatter.string(from: resetAt))"
        }
        return "Session resets in \(remaining) - \(resetFormatter.string(from: resetAt))"
    }

    /// Re-renders the countdown from the cached snapshot.
    ///
    /// `resets_at` is an absolute timestamp, so the time left can be recomputed
    /// locally as often as we like. This deliberately makes no network call --
    /// the poll stays at five minutes while the display stays current, and a
    /// stale reading keeps counting down behind its offline badge.
    private func redrawCountdown() {
        guard let snapshot = latestSnapshot else {
            return
        }
        let session = snapshot.window("five_hour") ?? snapshot.primary
        let stale = consecutiveFailures > 0
        sessionResetItem.title = sessionResetTitle(for: session)
        updateStatusImage(
            text: String(session.remainingPercent),
            detail: formatRemaining(until: session.resetAt),
            offline: stale
        )
    }

    private func startCountdownTimer() {
        displayTimer?.invalidate()
        // 20s keeps the minute digit honest without meaningful cost.
        displayTimer = Timer.scheduledTimer(
            withTimeInterval: 20,
            repeats: true
        ) { [weak self] _ in
            self?.redrawCountdown()
        }
    }

    private func apply(_ error: Error) {
        if let snapshot = latestSnapshot {
            let session = snapshot.window("five_hour") ?? snapshot.primary
            summaryItem.title = format(session) + " - STALE"
            // The reset time is absolute, so it stays valid while offline.
            sessionResetItem.title = sessionResetTitle(for: session)
            connectionItem.title = "OFFLINE - showing \(timeFormatter.string(from: snapshot.checkedAt)) reading"
            updateStatusImage(
                text: String(session.remainingPercent),
                detail: formatRemaining(until: session.resetAt),
                offline: true
            )
            return
        }
        summaryItem.title = "Claude subscription usage unavailable"
        sessionResetItem.title = truncated(error.localizedDescription, limit: 100)
        connectionItem.title = "OFFLINE - last attempt \(timeFormatter.string(from: Date()))"
        updateStatusImage(text: "!", detail: nil, offline: false)
    }

    private func updateStatusImage(text: String, detail: String?, offline: Bool) {
        statusItem.button?.image = statusImage(
            text: text,
            detail: detail,
            offline: offline
        )
        var description = "Claude usage \(text) percent remaining"
        if let detail = detail, detail != "now" {
            description += ", resets in \(detail)"
        } else if detail == "now" {
            description += ", resetting now"
        }
        description += (offline ? ", offline" : "")
        statusItem.button?.toolTip = description
        statusItem.button?.setAccessibilityLabel(description)
    }

    private func schedule(after seconds: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) {
            [weak self] _ in self?.refresh()
        }
    }

    private func retryDelay(for error: Error) -> TimeInterval {
        if let usageError = error as? UsageError,
           case .rateLimited(let serverDelay) = usageError {
            let index = min(rateLimitFailures, rateLimitRetryIntervals.count - 1)
            rateLimitFailures += 1
            return max(TimeInterval(serverDelay ?? 0), rateLimitRetryIntervals[index])
        }
        if let usageError = error as? UsageError,
           case .credential(_) = usageError {
            let index = min(credentialFailures, rateLimitRetryIntervals.count - 1)
            credentialFailures += 1
            return rateLimitRetryIntervals[index]
        }
        let index = min(consecutiveFailures - 1, offlineRetryIntervals.count - 1)
        return offlineRetryIntervals[index]
    }

    private func configuredRefreshInterval() -> TimeInterval {
        guard
            let raw = ProcessInfo.processInfo.environment[
                "CLAUDE_USAGE_TRAY_REFRESH_SECONDS"
            ],
            let seconds = Double(raw)
        else {
            return defaultRefreshInterval
        }
        return max(60, seconds)
    }

    @objc private func toggleStartAtLogin() {
        let requested = startAtLoginItem.state != .on
        do {
            try LaunchAgentManager.setEnabled(requested, executableURL: executableURL)
            startAtLoginItem.state = requested ? .on : .off
            connectionItem.title = requested
                ? "Start at login enabled"
                : "Start at login disabled"
            logger.info("Start at login set to \(requested ? "on" : "off").")
        } catch {
            connectionItem.title = "Startup setting failed: \(truncated(error.localizedDescription, limit: 70))"
            logger.error("Could not change startup registration: \(error.localizedDescription)")
        }
    }

    @objc private func openLogs() {
        NSWorkspace.shared.open(logger.directoryURL)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func format(_ window: UsageWindow) -> String {
        "\(window.label): \(window.remainingPercent)% left (\(window.usedPercent)% used)"
    }

    private func formatReset(_ prefix: String, _ date: Date?) -> String {
        guard let date = date else {
            return "\(prefix): unavailable"
        }
        return "\(prefix) \(resetFormatter.string(from: date))"
    }

    private func truncated(_ value: String, limit: Int) -> String {
        guard value.count > limit else {
            return value
        }
        return String(value.prefix(limit - 1)) + "…"
    }

    private lazy var timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm:ss a"
        return formatter
    }()

    private lazy var resetFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d 'at' h:mm a"
        return formatter
    }()
}

/// Child-process mode: resolve a usable Claude OAuth credential and print it as
/// `OK\t<service>\t<token>` (or `ERR\t<message>`), then exit without unwinding.
///
/// EVERY Security-framework call this app makes happens here, in a process that
/// exits moments later. That is deliberate, and it is the fix for the 0.2.1
/// crash loop.
///
/// The match-all + return-attributes sweep below walks every generic-password
/// item in the login Keychain, which is how the hash-suffixed
/// `Claude Code-credentials-<hash>` item -- the one Claude Code actually keeps
/// current -- gets found. Built with `swiftc -O` on macOS 26 that sweep leaves
/// the process heap corrupted. The scan returns correct data, but the damage
/// surfaces later and somewhere unrelated: first as SIGSEGV in the next
/// single-item Keychain read, and once that was isolated, as a malloc freelist
/// trap inside CFNetwork on the first HTTP request. Reducing it showed the fault is
/// in the legacy Keychain enumeration itself, not Swift's bridging -- a raw
/// CFArray/CFDictionary walk crashes identically, and scoping the query with
/// kSecUseDataProtectionKeychain avoids the crash but hides the hash-suffixed
/// items that hold the live token.
///
/// Rather than keep chasing where the damage lands, all Keychain work is
/// confined to this child. The parent never calls Security at all, so it cannot
/// inherit the corruption. Do not move any of this back into the parent --
/// tests/test_linux.py pins that boundary.
///
/// Only the service name and access token cross the pipe to the parent, and
/// neither is ever written to the log.
private func runCredentialEmit(rejecting rejected: Set<String>) -> Never {
    func emit(_ line: String) -> Never {
        print(line)
        // Flush by hand, because _exit() below will not do it for us.
        fflush(stdout)
        // _exit, not exit: this process's heap may already be corrupted, and
        // exit() would run atexit handlers plus Swift/CF runtime teardown on
        // it -- the very thing this child exists to contain. A crash in
        // teardown happens *after* a valid credential has been written to the
        // pipe, so the parent would see a nonzero status and silently discard
        // it. Skipping teardown costs nothing here: the kernel reclaims
        // everything, and stdout is already flushed.
        Darwin._exit(0)
    }

    // 1. Discover candidate service names, newest first.
    let scan: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecReturnAttributes as String: true,
        kSecMatchLimit as String: kSecMatchLimitAll,
    ]
    var scanResult: CFTypeRef?
    var modifiedByService: [String: Date] = [:]
    if SecItemCopyMatching(scan as CFDictionary, &scanResult) == errSecSuccess,
       let attributes = scanResult as? [[String: Any]] {
        for attribute in attributes {
            guard
                let serviceName = attribute[kSecAttrService as String] as? String,
                isClaudeCredentialService(serviceName)
            else {
                continue
            }
            let modifiedAt = attribute[kSecAttrModificationDate as String] as? Date
                ?? .distantPast
            if modifiedAt > (modifiedByService[serviceName] ?? .distantPast) {
                modifiedByService[serviceName] = modifiedAt
            }
        }
    }
    // Keep the legacy name as a final fallback even when the sweep is
    // unavailable, fails, or does not list it.
    if modifiedByService[keychainService] == nil {
        modifiedByService[keychainService] = .distantPast
    }
    let candidates = modifiedByService
        .map { KeychainCandidate(serviceName: $0.key, modifiedAt: $0.value) }
        .sorted {
            if $0.modifiedAt == $1.modifiedAt {
                return $0.serviceName < $1.serviceName
            }
            return $0.modifiedAt > $1.modifiedAt
        }

    // 2. Read them in order and emit the first that yields an access token.
    var lastFailure: String?
    var attempted = false
    for candidate in candidates where !rejected.contains(candidate.serviceName) {
        attempted = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: candidate.serviceName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                lastFailure = "No Claude.ai OAuth credential was found in macOS Keychain under '\(candidate.serviceName)'."
            } else {
                let detail = SecCopyErrorMessageString(status, nil) as String?
                lastFailure = "Could not read Claude's macOS Keychain credential: \(detail ?? "OSStatus \(status)")."
            }
            continue
        }
        guard let data = item as? Data else {
            lastFailure = "Claude's macOS Keychain credential had an unexpected shape."
            continue
        }
        do {
            // Service names and tokens contain no tabs, so this stays parseable.
            emit("OK\t\(candidate.serviceName)\t\(try accessToken(from: data))")
        } catch {
            lastFailure = error.localizedDescription
        }
    }

    if !attempted, !rejected.isEmpty {
        emit("ERR\tClaude rejected every matching macOS Keychain credential. Open Claude Code and run `/login`, then restart Claude Usage Tray.")
    }
    emit("ERR\t" + (lastFailure
        ?? "No Claude.ai OAuth credential was found in macOS Keychain. Sign Claude Code in with an eligible Claude.ai subscription."))
}

private func printSnapshot(_ snapshot: UsageSnapshot) {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss z"
    print("Claude subscription usage:")
    for window in snapshot.windows {
        let reset = window.resetAt.map { formatter.string(from: $0) } ?? "unknown"
        // Same countdown the menu bar shows, so --check can confirm it.
        let remaining = formatRemaining(until: window.resetAt).map { " (in \($0))" } ?? ""
        print(
            "  \(window.label): \(window.remainingPercent)% remaining (\(window.usedPercent)% used); resets \(reset)\(remaining)"
        )
    }
}

private func runMockCheck(path: String) -> Int32 {
    do {
        let snapshot = try UsageParser.parse(Data(contentsOf: URL(fileURLWithPath: path)))
        printSnapshot(snapshot)
        return 0
    } catch {
        fputs("Claude mock usage check failed: \(error.localizedDescription)\n", stderr)
        return 1
    }
}

private func runLiveCheck() -> Int32 {
    let client = UsageClient()
    let semaphore = DispatchSemaphore(value: 0)
    var resultCode: Int32 = 1
    client.getUsage { result in
        switch result {
        case .success(let snapshot):
            printSnapshot(snapshot)
            resultCode = 0
        case .failure(let error):
            fputs("Claude usage check failed: \(error.localizedDescription)\n", stderr)
        }
        semaphore.signal()
    }
    // Budget the Keychain approval wait as well, not just the HTTP timeout.
    let deadline = DispatchTime.now() + responseTimeout + credentialScanTimeout + 3
    if semaphore.wait(timeout: deadline) == .timedOut {
        fputs("Claude usage check failed: request timed out.\n", stderr)
        client.cancel()
        return 1
    }
    return resultCode
}

private let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--emit-credential" {
    // Hidden child mode -- see runCredentialEmit(rejecting:).
    var rejected: Set<String> = []
    var index = 1
    while index + 1 < arguments.count, arguments[index] == "--reject" {
        rejected.insert(arguments[index + 1])
        index += 2
    }
    runCredentialEmit(rejecting: rejected)
}
if arguments.count == 2, arguments[0] == "--mock-response" {
    Darwin.exit(runMockCheck(path: arguments[1]))
}
if arguments == ["--check"] {
    Darwin.exit(runLiveCheck())
}
if !arguments.isEmpty {
    fputs("Usage: ClaudeUsageTray [--check | --mock-response FILE]\n", stderr)
    Darwin.exit(2)
}

guard let instanceLock = SingleInstanceLock() else {
    Darwin.exit(0)
}
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
private let delegate = AppDelegate(executableURL: currentExecutableURL)
application.delegate = delegate
application.run()
withExtendedLifetime(instanceLock) {}

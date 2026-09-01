import AppKit
import CoreFoundation
import Darwin
import Foundation
import Security

private let appID = "claude-usage-tray"
private let appName = "Claude Usage Tray"
private let appVersion = "0.2.0"
private let usageEndpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
private let oauthBeta = "oauth-2025-04-20"
private let keychainService = "Claude Code-credentials"
private let responseTimeout: TimeInterval = 12
private let maximumResponseBytes = 256 * 1024
private let defaultRefreshInterval: TimeInterval = 5 * 60
private let offlineRetryIntervals: [TimeInterval] = [60, 2 * 60, 5 * 60]
private let rateLimitRetryIntervals: [TimeInterval] = [10 * 60, 30 * 60, 60 * 60]

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

    private func credentialFromKeychain() throws -> LoadedCredential {
        let candidates = keychainCandidates()
        var lastFailure: String?
        var attempted = false
        for candidate in candidates
        where !rejectedKeychainServices.contains(candidate.serviceName) {
            attempted = true
            do {
                return LoadedCredential(
                    token: try tokenFromKeychain(serviceName: candidate.serviceName),
                    keychainServiceName: candidate.serviceName
                )
            } catch {
                lastFailure = error.localizedDescription
            }
        }

        if !attempted, !rejectedKeychainServices.isEmpty {
            throw UsageError.credential(
                "Claude rejected every matching macOS Keychain credential. Open Claude Code and run `/login`, then restart Claude Usage Tray."
            )
        }
        throw UsageError.credential(
            lastFailure
                ?? "No Claude.ai OAuth credential was found in macOS Keychain. Sign Claude Code in with an eligible Claude.ai subscription."
        )
    }

    private func keychainCandidates() -> [KeychainCandidate] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        var modifiedByService: [String: Date] = [:]
        if status == errSecSuccess, let attributes = item as? [[String: Any]] {
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

        // Keep the legacy name as a final fallback even when broad attribute
        // discovery is unavailable or the item is absent from its result.
        if modifiedByService[keychainService] == nil {
            modifiedByService[keychainService] = .distantPast
        }
        return modifiedByService
            .map { KeychainCandidate(serviceName: $0.key, modifiedAt: $0.value) }
            .sorted {
                if $0.modifiedAt == $1.modifiedAt {
                    return $0.serviceName < $1.serviceName
                }
                return $0.modifiedAt > $1.modifiedAt
            }
    }

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

    private func tokenFromKeychain(serviceName: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw UsageError.credential(
                    "No Claude.ai OAuth credential was found in macOS Keychain under '\(serviceName)'."
                )
            }
            let detail = SecCopyErrorMessageString(status, nil) as String?
            throw UsageError.credential(
                "Could not read Claude's macOS Keychain credential: \(detail ?? "OSStatus \(status)")."
            )
        }
        guard let data = item as? Data else {
            throw UsageError.credential(
                "Claude's macOS Keychain credential had an unexpected shape."
            )
        }
        return try accessToken(from: data)
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
}

private final class UsageClient {
    private let credentials = CredentialStore()
    private let session: URLSession
    private var task: URLSessionDataTask?

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = responseTimeout
        configuration.timeoutIntervalForResource = responseTimeout
        session = URLSession(configuration: configuration)
    }

    func getUsage(completion: @escaping (Result<UsageSnapshot, Error>) -> Void) {
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

        task = session.dataTask(with: request) { [weak self] data, response, error in
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
        task?.resume()
    }

    func cancel() {
        task?.cancel()
        task = nil
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

private func statusImage(text: String, offline: Bool) -> NSImage {
    let size = NSSize(width: 28, height: 18)
    let image = NSImage(size: size, flipped: false) { rect in
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
        return true
    }
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
    private var weeklyItem: NSMenuItem!
    private var weeklyResetItem: NSMenuItem!
    private var allLimitsItem: NSMenuItem!
    private var connectionItem: NSMenuItem!
    private var refreshItem: NSMenuItem!
    private var startAtLoginItem: NSMenuItem!
    private var timer: Timer?
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
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        client.cancel()
        logger.info("\(appName) exiting.")
    }

    private func configureMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: 28)
        statusItem.button?.image = statusImage(text: "?", offline: false)
        statusItem.button?.toolTip = "Claude usage loading"
        statusItem.button?.setAccessibilityLabel("Claude usage loading")

        menu = NSMenu()
        menu.autoenablesItems = false
        summaryItem = disabledItem("Claude usage: loading…")
        sessionResetItem = disabledItem("Session reset: loading…")
        weeklyItem = disabledItem("Weekly usage: loading…")
        weeklyResetItem = disabledItem("Weekly reset: loading…")
        allLimitsItem = NSMenuItem(title: "All usage windows", action: nil, keyEquivalent: "")
        allLimitsItem.isEnabled = false
        connectionItem = disabledItem("Connection: loading…")
        let informationItems: [NSMenuItem] = [
            summaryItem,
            sessionResetItem,
            weeklyItem,
            weeklyResetItem,
            allLimitsItem,
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
        let weekly = snapshot.window("seven_day")
        summaryItem.title = format(session)
        sessionResetItem.title = formatReset("Session resets", session.resetAt)
        if let weekly = weekly {
            weeklyItem.title = format(weekly)
            weeklyResetItem.title = formatReset("Week resets", weekly.resetAt)
        } else {
            weeklyItem.title = "Weekly usage unavailable"
            weeklyResetItem.title = "Weekly reset unavailable"
        }
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for window in snapshot.windows {
            submenu.addItem(disabledItem(format(window)))
            submenu.addItem(disabledItem(formatReset("Resets", window.resetAt)))
        }
        allLimitsItem.submenu = submenu
        allLimitsItem.isEnabled = true
        connectionItem.title = "Online - updated \(timeFormatter.string(from: snapshot.checkedAt))"
        updateStatusImage(text: String(session.remainingPercent), offline: false)
    }

    private func apply(_ error: Error) {
        if let snapshot = latestSnapshot {
            summaryItem.title = format(snapshot.primary) + " - STALE"
            connectionItem.title = "OFFLINE - showing \(timeFormatter.string(from: snapshot.checkedAt)) reading"
            updateStatusImage(
                text: String(snapshot.primary.remainingPercent),
                offline: true
            )
            return
        }
        summaryItem.title = "Claude subscription usage unavailable"
        sessionResetItem.title = truncated(error.localizedDescription, limit: 100)
        weeklyItem.title = "Weekly usage unavailable"
        weeklyResetItem.title = "Weekly reset unavailable"
        allLimitsItem.isEnabled = false
        connectionItem.title = "OFFLINE - last attempt \(timeFormatter.string(from: Date()))"
        updateStatusImage(text: "!", offline: false)
    }

    private func updateStatusImage(text: String, offline: Bool) {
        statusItem.button?.image = statusImage(text: text, offline: offline)
        let description = "Claude usage \(text) percent remaining"
            + (offline ? ", offline" : "")
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

private func printSnapshot(_ snapshot: UsageSnapshot) {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss z"
    print("Claude subscription usage:")
    for window in snapshot.windows {
        let reset = window.resetAt.map { formatter.string(from: $0) } ?? "unknown"
        print(
            "  \(window.label): \(window.remainingPercent)% remaining (\(window.usedPercent)% used); resets \(reset)"
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
    if semaphore.wait(timeout: .now() + responseTimeout + 3) == .timedOut {
        fputs("Claude usage check failed: request timed out.\n", stderr)
        client.cancel()
        return 1
    }
    return resultCode
}

private let arguments = Array(CommandLine.arguments.dropFirst())
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
let executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    .standardizedFileURL
    .resolvingSymlinksInPath()
private let delegate = AppDelegate(executableURL: executableURL)
application.delegate = delegate
application.run()
withExtendedLifetime(instanceLock) {}

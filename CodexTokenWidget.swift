import AppKit
import Foundation

struct WidgetConfig: Decodable {
    var sessionsRootPath: String?
    var refreshSeconds: Double?
    var alwaysOnTop: Bool?
    var opacity: Double?
    var windowX: Int?
    var windowY: Int?
}

struct RateWindow {
    let name: String
    let remainingPercent: Int
    let resetText: String
    let fillFraction: Double
}

struct RateLimitSnapshot {
    let planType: String
    let primary: RateWindow
    let secondary: RateWindow
    let capturedAt: Date
}

struct WidgetMetrics {
    let title: String
    let primary: RateWindow?
    let secondary: RateWindow?
    let status: String
}

final class CodexRateLimitReader {
    private let home = FileManager.default.homeDirectoryForCurrentUser.path
    private let config: WidgetConfig
    private let resetTimeFormatter: DateFormatter
    private let resetDateFormatter: DateFormatter

    init(config: WidgetConfig) {
        self.config = config

        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.dateFormat = "h:mm a"
        self.resetTimeFormatter = timeFormatter

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "MMM d"
        self.resetDateFormatter = dateFormatter
    }

    func metrics() -> WidgetMetrics {
        guard let snapshot = readLatestSnapshot() else {
            return WidgetMetrics(
                title: "CODEX LIMITS",
                primary: nil,
                secondary: nil,
                status: "Waiting for Codex rate-limit event"
            )
        }

        let age = max(0, Int(Date().timeIntervalSince(snapshot.capturedAt)))
        return WidgetMetrics(
            title: "CODEX LIMITS",
            primary: snapshot.primary,
            secondary: snapshot.secondary,
            status: "\(snapshot.planType.uppercased())  ·  updated \(formatAge(age)) ago"
        )
    }

    private func readLatestSnapshot() -> RateLimitSnapshot? {
        for file in recentSessionFiles().prefix(20) {
            if let snapshot = readSnapshot(from: file) {
                return snapshot
            }
        }
        return nil
    }

    private func recentSessionFiles() -> [URL] {
        let root = URL(fileURLWithPath: expand(config.sessionsRootPath ?? "~/.codex/sessions"))
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [(url: URL, modified: Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            files.append((url, values?.contentModificationDate ?? .distantPast))
        }
        return files.sorted { $0.modified > $1.modified }.map(\.url)
    }

    private func readSnapshot(from file: URL) -> RateLimitSnapshot? {
        guard let text = tail(file: file, maxBytes: 8_000_000) else { return nil }
        for line in text.components(separatedBy: .newlines).reversed() {
            guard line.contains("\"rate_limits\""),
                  let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "event_msg",
                  let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let rateLimits = payload["rate_limits"] as? [String: Any],
                  let snapshot = snapshot(from: rateLimits, timestamp: object["timestamp"] as? String)
            else { continue }
            return snapshot
        }
        return nil
    }

    private func tail(file: URL, maxBytes: UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > maxBytes ? size - maxBytes : 0
        try? handle.seek(toOffset: start)
        let data = handle.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    private func snapshot(from rateLimits: [String: Any], timestamp: String?) -> RateLimitSnapshot? {
        guard let primaryJSON = rateLimits["primary"] as? [String: Any],
              let secondaryJSON = rateLimits["secondary"] as? [String: Any],
              let primary = parseWindow(primaryJSON),
              let secondary = parseWindow(secondaryJSON)
        else { return nil }

        let planType = (rateLimits["plan_type"] as? String) ?? "unknown"
        let capturedAt = parseTimestamp(timestamp) ?? Date()
        return RateLimitSnapshot(planType: planType, primary: primary, secondary: secondary, capturedAt: capturedAt)
    }

    private func parseWindow(_ json: [String: Any]) -> RateWindow? {
        guard let usedPercent = number(json["used_percent"]),
              let windowMinutes = number(json["window_minutes"]),
              let resetAt = number(json["resets_at"]) ?? number(json["reset_at"])
        else { return nil }

        let remaining = max(0, min(100, Int((100.0 - usedPercent).rounded())))
        let resetDate = Date(timeIntervalSince1970: resetAt)
        return RateWindow(
            name: windowName(Int(windowMinutes)),
            remainingPercent: remaining,
            resetText: resetText(for: resetDate, windowMinutes: Int(windowMinutes)),
            fillFraction: min(1.0, max(0.0, Double(remaining) / 100.0))
        )
    }

    private func windowName(_ minutes: Int) -> String {
        if minutes >= 7 * 24 * 60 { return "Weekly" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }

    private func resetText(for date: Date, windowMinutes: Int) -> String {
        if windowMinutes >= 24 * 60 {
            return resetDateFormatter.string(from: date)
        }
        return resetTimeFormatter.string(from: date)
    }

    private func parseTimestamp(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }

    private func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }

    private func expand(_ path: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + String(path.dropFirst()) }
        return path
    }
}

final class PixelBar: NSView {
    var fraction: Double = 0 {
        didSet {
            fraction = min(1.0, max(0.0, fraction))
            needsDisplay = true
        }
    }

    var activeColor = NSColor(calibratedRed: 0.34, green: 0.95, blue: 0.78, alpha: 1)
    var inactiveColor = NSColor(calibratedRed: 0.16, green: 0.18, blue: 0.23, alpha: 1)

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setShouldAntialias(false)

        let segments = 12
        let gap: CGFloat = 2
        let totalGap = CGFloat(segments - 1) * gap
        let segmentWidth = floor((bounds.width - totalGap) / CGFloat(segments))
        let filled = Int((fraction * Double(segments)).rounded(.toNearestOrAwayFromZero))

        for index in 0..<segments {
            let x = CGFloat(index) * (segmentWidth + gap)
            let rect = NSRect(x: x, y: 0, width: segmentWidth, height: bounds.height)
            (index < filled ? activeColor : inactiveColor).setFill()
            rect.fill()
        }
    }
}

final class WidgetContentView: NSView {
    private let titleDot = NSView()
    private let titleLabel = NSTextField(labelWithString: "CODEX LIMITS")
    private let primaryName = NSTextField(labelWithString: "--")
    private let primaryPercent = NSTextField(labelWithString: "--")
    private let primaryReset = NSTextField(labelWithString: "--")
    private let primaryProgress = PixelBar()
    private let secondaryName = NSTextField(labelWithString: "--")
    private let secondaryPercent = NSTextField(labelWithString: "--")
    private let secondaryReset = NSTextField(labelWithString: "--")
    private let secondaryProgress = PixelBar()
    private let status = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.backgroundColor = NSColor(calibratedRed: 0.045, green: 0.052, blue: 0.075, alpha: 0.94).cgColor
        layer?.borderColor = NSColor(calibratedRed: 0.34, green: 0.95, blue: 0.78, alpha: 0.76).cgColor
        layer?.borderWidth = 2
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ metrics: WidgetMetrics) {
        titleLabel.stringValue = metrics.title
        if let primary = metrics.primary {
            primaryName.stringValue = primary.name
            primaryPercent.stringValue = "\(primary.remainingPercent)%"
            primaryReset.stringValue = primary.resetText
            primaryProgress.fraction = primary.fillFraction
        } else {
            primaryName.stringValue = "--"
            primaryPercent.stringValue = "--"
            primaryReset.stringValue = "--"
            primaryProgress.fraction = 0
        }

        if let secondary = metrics.secondary {
            secondaryName.stringValue = secondary.name
            secondaryPercent.stringValue = "\(secondary.remainingPercent)%"
            secondaryReset.stringValue = secondary.resetText
            secondaryProgress.fraction = secondary.fillFraction
        } else {
            secondaryName.stringValue = "--"
            secondaryPercent.stringValue = "--"
            secondaryReset.stringValue = "--"
            secondaryProgress.fraction = 0
        }
        status.stringValue = metrics.status
    }

    private func setup() {
        let views: [NSView] = [
            titleDot, titleLabel,
            primaryName, primaryPercent, primaryReset, primaryProgress,
            secondaryName, secondaryPercent, secondaryReset, secondaryProgress,
            status
        ]
        views.forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }

        titleDot.wantsLayer = true
        titleDot.layer?.backgroundColor = NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.28, alpha: 1).cgColor

        titleLabel.font = .monospacedSystemFont(ofSize: 9, weight: .bold)
        titleLabel.textColor = NSColor(calibratedRed: 0.91, green: 0.96, blue: 0.94, alpha: 1)

        [primaryName, secondaryName].forEach {
            $0.font = .monospacedSystemFont(ofSize: 10, weight: .bold)
            $0.textColor = NSColor(calibratedRed: 0.91, green: 0.96, blue: 0.94, alpha: 1)
        }
        [primaryPercent, secondaryPercent, primaryReset, secondaryReset].forEach {
            $0.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
            $0.textColor = NSColor(calibratedRed: 0.62, green: 0.68, blue: 0.78, alpha: 1)
            $0.alignment = .right
        }

        primaryProgress.activeColor = NSColor(calibratedRed: 0.34, green: 0.95, blue: 0.78, alpha: 1)
        secondaryProgress.activeColor = NSColor(calibratedRed: 0.42, green: 0.68, blue: 1.0, alpha: 1)

        status.font = .monospacedSystemFont(ofSize: 7, weight: .medium)
        status.textColor = NSColor(calibratedRed: 0.48, green: 0.54, blue: 0.64, alpha: 1)
        status.lineBreakMode = .byTruncatingTail

        NSLayoutConstraint.activate([
            titleDot.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            titleDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleDot.widthAnchor.constraint(equalToConstant: 7),
            titleDot.heightAnchor.constraint(equalToConstant: 7),

            titleLabel.centerYAnchor.constraint(equalTo: titleDot.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: titleDot.trailingAnchor, constant: 7),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            primaryName.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            primaryName.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            primaryName.widthAnchor.constraint(equalToConstant: 56),

            primaryReset.centerYAnchor.constraint(equalTo: primaryName.centerYAnchor),
            primaryReset.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            primaryReset.widthAnchor.constraint(equalToConstant: 58),

            primaryPercent.centerYAnchor.constraint(equalTo: primaryName.centerYAnchor),
            primaryPercent.trailingAnchor.constraint(equalTo: primaryReset.leadingAnchor, constant: -8),
            primaryPercent.widthAnchor.constraint(equalToConstant: 38),

            primaryProgress.topAnchor.constraint(equalTo: primaryName.bottomAnchor, constant: 5),
            primaryProgress.leadingAnchor.constraint(equalTo: primaryName.leadingAnchor),
            primaryProgress.trailingAnchor.constraint(equalTo: primaryReset.trailingAnchor),
            primaryProgress.heightAnchor.constraint(equalToConstant: 6),

            secondaryName.topAnchor.constraint(equalTo: primaryProgress.bottomAnchor, constant: 7),
            secondaryName.leadingAnchor.constraint(equalTo: primaryName.leadingAnchor),
            secondaryName.widthAnchor.constraint(equalTo: primaryName.widthAnchor),

            secondaryReset.centerYAnchor.constraint(equalTo: secondaryName.centerYAnchor),
            secondaryReset.trailingAnchor.constraint(equalTo: primaryReset.trailingAnchor),
            secondaryReset.widthAnchor.constraint(equalTo: primaryReset.widthAnchor),

            secondaryPercent.centerYAnchor.constraint(equalTo: secondaryName.centerYAnchor),
            secondaryPercent.trailingAnchor.constraint(equalTo: secondaryReset.leadingAnchor, constant: -10),
            secondaryPercent.widthAnchor.constraint(equalTo: primaryPercent.widthAnchor),

            secondaryProgress.topAnchor.constraint(equalTo: secondaryName.bottomAnchor, constant: 5),
            secondaryProgress.leadingAnchor.constraint(equalTo: secondaryName.leadingAnchor),
            secondaryProgress.trailingAnchor.constraint(equalTo: secondaryReset.trailingAnchor),
            secondaryProgress.heightAnchor.constraint(equalToConstant: 6),

            status.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            status.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5)
        ])
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var reader: CodexRateLimitReader!
    private var content: WidgetContentView!
    private var timer: Timer?
    private var config: WidgetConfig!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        config = loadConfig()
        reader = CodexRateLimitReader(config: config)

        let frame = initialFrame(config)
        content = WidgetContentView(frame: NSRect(origin: .zero, size: frame.size))
        window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = content
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.alphaValue = config.opacity ?? 0.98
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.level = (config.alwaysOnTop ?? true) ? .floating : .normal
        window.makeKeyAndOrderFront(nil)

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: max(5, config.refreshSeconds ?? 20), repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func refresh() {
        content.apply(reader.metrics())
    }

    private func initialFrame(_ config: WidgetConfig) -> NSRect {
        let size = NSSize(width: 244, height: 96)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = CGFloat(config.windowX ?? Int(screen.midX - size.width / 2))
        let y = CGFloat(config.windowY ?? Int(screen.maxY - size.height - 6))
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    private func loadConfig() -> WidgetConfig {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("codex-token-widget/config.json")
        guard let data = try? Data(contentsOf: path),
              let config = try? JSONDecoder().decode(WidgetConfig.self, from: data)
        else {
            return WidgetConfig(
                sessionsRootPath: nil,
                refreshSeconds: 20,
                alwaysOnTop: true,
                opacity: 0.98,
                windowX: nil,
                windowY: nil
            )
        }
        return config
    }
}

private func formatAge(_ seconds: Int) -> String {
    if seconds < 60 { return "\(seconds)s" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    if hours < 24 { return "\(hours)h" }
    return "\(hours / 24)d"
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

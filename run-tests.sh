#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
TMPDIR="$(mktemp -d /private/tmp/codex-token-widget-tests.XXXXXX)"
trap 'rm -rf "$TMPDIR"' EXIT

SOURCE="$TMPDIR/CodexTokenWidgetTest.swift"
sed '/^if CommandLine.arguments.contains("--print")/,$d' "$ROOT/CodexTokenWidget.swift" > "$SOURCE"
cat >> "$SOURCE" <<SWIFT

func assertEqual(_ actual: Int?, _ expected: Int, _ message: String) {
    guard actual == expected else {
        fputs("FAIL: \(message). expected \(expected), got \(String(describing: actual))\n", stderr)
        Darwin.exit(1)
    }
}

let sessionsRoot = URL(fileURLWithPath: "$TMPDIR").appendingPathComponent("sessions")
try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
let sessionFile = sessionsRoot.appendingPathComponent("session.jsonl")
let jsonLine = """
{"timestamp":"2026-05-25T09:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":7.0,"window_minutes":300,"resets_at":1779706533},"secondary":{"used_percent":8.0,"window_minutes":10080,"resets_at":1780191944},"credits":null,"plan_type":"pro","rate_limit_reached_type":null}}}
{"timestamp":"2026-05-25T09:20:00.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex_bengalfox","limit_name":"GPT-5.3-Codex-Spark","primary":{"used_percent":0.0,"window_minutes":300,"resets_at":1779708000},"secondary":{"used_percent":0.0,"window_minutes":10080,"resets_at":1780193000},"credits":null,"plan_type":"pro","rate_limit_reached_type":null}}}
"""
try jsonLine.write(to: sessionFile, atomically: true, encoding: .utf8)

let reader = CodexRateLimitReader(config: WidgetConfig(
    sessionsRootPath: sessionsRoot.path,
    refreshSeconds: nil,
    alwaysOnTop: nil,
    opacity: nil,
    windowX: nil,
    windowY: nil
))
let metrics = reader.metrics()
assertEqual(metrics.primary?.remainingPercent, 93, "primary displays remaining percentage")
assertEqual(metrics.secondary?.remainingPercent, 92, "secondary displays remaining percentage")
print("rate limit percentage tests passed")
SWIFT

swift "$SOURCE"

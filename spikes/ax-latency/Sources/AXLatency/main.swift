import AppKit
import ApplicationServices
import Foundation

// Shotfuse Spike A — AX tree extraction latency benchmark.
// Measures wall-clock cost of reading { bundle_id, window_title, file/browser URL }
// from the frontmost window via AXUIElement APIs. See spikes/ax-latency/README.md.

let targets: [(name: String, bundleID: String)] = [
    ("Xcode",    "com.apple.dt.Xcode"),
    ("VS Code",  "com.microsoft.VSCode"),
    ("Safari",   "com.apple.Safari"),
    ("Slack",    "com.tinyspeck.slackmacgap"),
    ("Obsidian", "md.obsidian"),
]
let iterations = 20
let activationSettleSeconds = 0.6

guard AXIsProcessTrusted() else {
    fputs("""
    [error] Accessibility permission not granted to this process.

    Fix: System Settings → Privacy & Security → Accessibility → add the binary that
    runs this benchmark. When invoked via `swift run`, the binary path changes per
    build; the simplest fix is to either (a) grant Accessibility to Terminal.app (or
    the host terminal), or (b) `swift build -c release` and grant AX to the stable
    path printed by `swift build -c release --show-bin-path`/AXLatency.

    """, stderr)
    exit(2)
}

func copyAttr(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func firstURL(_ element: AXUIElement) -> String? {
    if let raw = copyAttr(element, kAXURLAttribute) {
        if CFGetTypeID(raw) == CFURLGetTypeID() { return (raw as! URL).absoluteString }
        if let s = raw as? String { return s }
    }
    if let doc = copyAttr(element, kAXDocumentAttribute) as? String { return doc }
    return nil
}

func extract(pid: pid_t) -> (title: String?, url: String?) {
    let app = AXUIElementCreateApplication(pid)
    guard let windowRef = copyAttr(app, kAXFocusedWindowAttribute) else { return (nil, nil) }
    let window = windowRef as! AXUIElement
    let title = copyAttr(window, kAXTitleAttribute) as? String
    var url = firstURL(window)
    if url == nil, let focusedRef = copyAttr(app, kAXFocusedUIElementAttribute) {
        url = firstURL(focusedRef as! AXUIElement)
    }
    return (title, url)
}

struct AppResult {
    let name: String
    let bundleID: String
    let samplesMs: [Double]
    let lastTitle: String?
    let lastURL: String?
}

func percentiles(_ samples: [Double]) -> (p50: Double, p95: Double, p99: Double, min: Double, max: Double) {
    let s = samples.sorted()
    func pct(_ p: Double) -> Double {
        let idx = Int(ceil(p * Double(s.count))) - 1
        return s[max(0, min(s.count - 1, idx))]
    }
    return (pct(0.50), pct(0.95), pct(0.99), s.first ?? 0, s.last ?? 0)
}

func report(label: String, samples: [Double]) {
    guard !samples.isEmpty else {
        print(String(format: "%-12@  n=  0  (no samples)", label as NSString))
        return
    }
    let p = percentiles(samples)
    print(String(format: "%-12@  n=%3d  p50=%6.2fms  p95=%6.2fms  p99=%6.2fms  min=%6.2fms  max=%6.2fms",
                 label as NSString, samples.count, p.p50, p.p95, p.p99, p.min, p.max))
}

var results: [AppResult] = []

for (name, bundleID) in targets {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
        fputs("[skip] \(name) (\(bundleID)) — not running. Launch it once and re-run.\n", stderr)
        continue
    }
    app.activate()
    Thread.sleep(forTimeInterval: activationSettleSeconds)

    let clock = ContinuousClock()
    var samplesMs: [Double] = []
    var lastTitle: String?
    var lastURL: String?

    for _ in 0..<iterations {
        let start = clock.now
        let (title, url) = extract(pid: app.processIdentifier)
        let elapsed = start.duration(to: clock.now)
        let comps = elapsed.components
        let ns = comps.seconds * 1_000_000_000 + comps.attoseconds / 1_000_000_000
        samplesMs.append(Double(ns) / 1_000_000.0)
        lastTitle = title
        lastURL = url
    }

    results.append(AppResult(name: name, bundleID: bundleID, samplesMs: samplesMs, lastTitle: lastTitle, lastURL: lastURL))
}

print("")
print("Shotfuse AX latency spike — \(iterations) iters/app")
print(String(repeating: "-", count: 72))
for r in results {
    report(label: r.name, samples: r.samplesMs)
    let title = r.lastTitle ?? "<nil>"
    let url = r.lastURL ?? "<nil>"
    print("              title: \(title)")
    print("              url:   \(url)")
}
print(String(repeating: "-", count: 72))
let all = results.flatMap(\.samplesMs)
report(label: "ALL", samples: all)

let decision: String
if all.isEmpty {
    decision = "indeterminate (no samples)"
} else {
    let p95 = percentiles(all).p95
    decision = p95 <= 50.0
        ? "DECISION: sync at capture time (p95 \(String(format: "%.2f", p95))ms ≤ 50ms)"
        : "DECISION: async post-capture enrichment (p95 \(String(format: "%.2f", p95))ms > 50ms)"
}
print(decision)

// Checks for the pure logic: response parsing, the remaining-amount rule,
// backoff, and launch-argument parsing. Run with `swift run ClaudeUsageBarChecks`.
//
// This is an executable rather than an XCTest target on purpose: Command Line
// Tools ship no XCTest, and the repo must stay buildable and checkable without
// Xcode. UsageAPI.swift and LaunchOptions.swift are symlinked into this target,
// so they are compiled from the same source the app uses.
//
// Nothing here touches the network, the keychain, or the real API.

import Foundation

var failures = 0
var checks = 0

func check(_ name: String, _ condition: @autoclosure () -> Bool, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if condition() { return }
    failures += 1
    let extra = detail()
    FileHandle.standardError.write(Data("FAIL: \(name)\(extra.isEmpty ? "" : " — \(extra)")\n".utf8))
}

func equal<T: Equatable>(_ name: String, _ got: T, _ want: T) {
    check(name, got == want, "got \(got), want \(want)")
}

let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

// MARK: - Parsing the sample response

let fixture = repoRoot.appendingPathComponent("Fixtures/usage_sample.json")
guard let sample = try? Data(contentsOf: fixture) else {
    FileHandle.standardError.write(Data("FAIL: cannot read \(fixture.path)\n".utf8))
    exit(1)
}

let rows = UsageAPI.parse(sample)
equal("fixture: row count", rows.count, 2)
equal("fixture: first id", rows.first?.id ?? "", "five_hour")
equal("fixture: first title", rows.first?.title ?? "", "Session (5h)")
equal("fixture: first utilization", rows.first?.utilization ?? -1, 40)
equal("fixture: second id", rows.dropFirst().first?.id ?? "", "seven_day")
equal("fixture: second utilization", rows.dropFirst().first?.utilization ?? -1, 25)
check("fixture: fractional seconds parsed", rows.first?.resetsAt != nil)

// Every user-facing number is what is left, not what was used.
let beforeReset = Date(timeIntervalSince1970: 0)
equal("remaining: 40 used -> 60 left", rows.first?.remaining(at: beforeReset) ?? -1, 60)

// MARK: - A window whose reset time has passed counts as fully available

let past = LimitRow(id: "x", title: "x", utilization: 90, resetsAt: Date(timeIntervalSince1970: 0))
equal("past reset -> 100 left", past.remaining(at: Date()) ?? -1, 100)
let future = LimitRow(id: "x", title: "x", utilization: 90, resetsAt: Date(timeIntervalSinceNow: 3600))
equal("future reset -> 10 left", future.remaining(at: Date()) ?? -1, 10)
let noValue = LimitRow(id: "x", title: "x", utilization: nil, resetsAt: nil)
check("missing utilization -> nil", noValue.remaining(at: Date()) == nil)
let overflow = LimitRow(id: "x", title: "x", utilization: 140, resetsAt: nil)
equal("utilization over 100 clamps to 0 left", overflow.remaining(at: Date()) ?? -1, 0)

// MARK: - Unknown, missing, or broken fields must never crash

equal("empty data -> no rows", UsageAPI.parse(Data()).count, 0)
equal("garbage -> no rows", UsageAPI.parse(Data("not json".utf8)).count, 0)
equal("json array -> no rows", UsageAPI.parse(Data("[1,2,3]".utf8)).count, 0)
equal("empty object -> no rows", UsageAPI.parse(Data("{}".utf8)).count, 0)
equal("null windows -> no rows", UsageAPI.parse(Data(#"{"five_hour":null,"seven_day":null}"#.utf8)).count, 0)

let wrongTypes = #"{"five_hour":{"utilization":"40","resets_at":42},"unknown_field":{"a":1}}"#
let wrongRows = UsageAPI.parse(Data(wrongTypes.utf8))
equal("wrong types -> row kept", wrongRows.count, 1)
check("wrong types -> utilization dropped", wrongRows.first?.utilization == nil)
check("wrong types -> reset dropped", wrongRows.first?.resetsAt == nil)

// true must not be read as utilization 1.
let boolean = UsageAPI.parse(Data(#"{"five_hour":{"utilization":true}}"#.utf8))
check("boolean utilization dropped", boolean.first?.utilization == nil)

equal("reset without fractional seconds",
      UsageAPI.parse(Data(#"{"five_hour":{"utilization":10,"resets_at":"2030-01-01T05:00:00+00:00"}}"#.utf8))
        .first?.resetsAt ?? Date(timeIntervalSince1970: 0),
      ISO8601DateFormatter().date(from: "2030-01-01T05:00:00Z")!)

// MARK: - Model-specific windows (only ever seen as null against real data)

let modelWindows = #"""
{"five_hour":{"utilization":10},"seven_day":{"utilization":20},
 "seven_day_opus":{"utilization":30},"seven_day_sonnet":{"utilization":40}}
"""#
let withModels = UsageAPI.parse(Data(modelWindows.utf8))
equal("model windows: row count", withModels.count, 4)
equal("model windows: opus title", withModels[2].title, "Weekly · Opus")
equal("model windows: sonnet utilization", withModels[3].utilization ?? -1, 40)

// The `limits` array is the fallback shape.
let limitsArray = #"""
{"limits":[{"kind":"session","percent":15,"resets_at":"2030-01-01T05:00:00+00:00"},
           {"kind":"weekly_all","percent":25},
           {"kind":"weekly_model","scope":"opus","percent":35}]}
"""#
let fromLimits = UsageAPI.parse(Data(limitsArray.utf8))
equal("limits array: row count", fromLimits.count, 3)
equal("limits array: session percent", fromLimits[0].utilization ?? -1, 15)
equal("limits array: model id", fromLimits[2].id, "limit-weekly_model")
equal("limits array: model title uses scope", fromLimits[2].title, "Weekly · opus")

// MARK: - Backoff

equal("backoff: starts at 300", BackoffPolicy.initialBackoff, 300)
equal("backoff: normal interval stays 180", BackoffPolicy.normalInterval, 180)

var policy = BackoffPolicy()
equal("backoff: first wait", policy.rateLimited(retryAfter: nil), 300)
equal("backoff: doubles", policy.rateLimited(retryAfter: nil), 600)
equal("backoff: doubles again", policy.rateLimited(retryAfter: nil), 1200)
equal("backoff: caps at 1800", policy.rateLimited(retryAfter: nil), 1800)
equal("backoff: stays capped", policy.rateLimited(retryAfter: nil), 1800)
policy.succeeded()
equal("backoff: reset after success", policy.rateLimited(retryAfter: nil), 300)

var withHeader = BackoffPolicy()
equal("backoff: longer Retry-After wins", withHeader.rateLimited(retryAfter: 900), 900)
var shortHeader = BackoffPolicy()
equal("backoff: shorter Retry-After ignored", shortHeader.rateLimited(retryAfter: 5), 300)

// MARK: - Launch arguments

func parsed(_ args: [String]) -> LaunchOptions? {
    try? LaunchOptions.parse(args)
}

func rejects(_ args: [String]) -> Bool {
    do {
        _ = try LaunchOptions.parse(args)
        return false
    } catch {
        return true
    }
}

check("no arguments -> real mode", parsed([])?.isMock == false)
equal("--mock 27", parsed(["--mock", "27"])?.mockUtilization ?? -1, 27)
equal("--mock without a value defaults to 30", parsed(["--mock"])?.mockUtilization ?? -1, 30)
equal("--mock clamps above 100", parsed(["--mock", "140"])?.mockUtilization ?? -1, 100)
equal("--mock clamps below 0", parsed(["--mock", "-5"])?.mockUtilization ?? -1, 0)
check("--mock-error expired", parsed(["--mock-error", "expired"])?.mockError == .expired)
check("--check-token", parsed(["--check-token"])?.checkToken == true)
equal("--render-icons keeps the path", parsed(["--render-icons", "/tmp/i"])?.renderIconsDirectory ?? "", "/tmp/i")
check("--api-url loopback accepted", parsed(["--api-url", "http://127.0.0.1:8080/"])?.apiURL != nil)
check("--api-url localhost accepted", parsed(["--api-url", "http://localhost:8080/"])?.apiURL != nil)

// A misparsed flag must never fall through to real mode and call the API.
check("unknown flag rejected", rejects(["--bogus"]))
check("bare word rejected", rejects(["oops"]))
check("--mock 27 as one word rejected", rejects(["--mock 27"]))
check("--mock-error with a bad value rejected", rejects(["--mock-error", "nope"]))
check("--render-icons without a value rejected", rejects(["--render-icons"]))
check("--api-url without a value rejected", rejects(["--api-url"]))

// The token may only ever go to a loopback host.
check("--api-url https rejected", rejects(["--api-url", "https://example.com/"]))
check("--api-url remote host rejected", rejects(["--api-url", "http://example.com/"]))
check("--api-url no scheme rejected", rejects(["--api-url", "127.0.0.1:8080"]))
check("--api-url lookalike host rejected", rejects(["--api-url", "http://127.0.0.1.example.com/"]))

// Cocoa-style "-Key value" pairs are left to AppKit rather than rejected.
check("-AppleLanguages pair accepted", parsed(["-AppleLanguages", "(en)"]) != nil)
equal("-AppleLanguages pair does not disturb --mock",
      parsed(["--mock", "27", "-AppleLanguages", "(en)"])?.mockUtilization ?? -1, 27)

// MARK: - Result

if failures > 0 {
    FileHandle.standardError.write(Data("\n\(failures) of \(checks) checks failed\n".utf8))
    exit(1)
}
print("\(checks) checks passed")

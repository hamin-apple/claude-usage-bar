# CLAUDE.md

Maintenance notes for Claude Code (and humans) working on this repo. User-facing docs are in `README.md`; read it first for behavior, launch arguments, and icon replacement.

## What this is

A native macOS menu bar app (SwiftUI `MenuBarExtra`, SwiftPM, no third-party dependencies) that shows the **remaining** claude.ai session (5h) and weekly (7d) limits. It borrows the OAuth token Claude Code keeps in the keychain and polls an unofficial endpoint. Every user-facing percentage is remaining (`100 - utilization`), never used.

## Commands

```bash
swift build                                        # debug build, checks the code compiles
.build/debug/ClaudeUsageBar --mock 27              # UI check with no API call (27% used -> 73% left)
.build/debug/ClaudeUsageBar --mock-error expired   # also: login | ratelimit | offline (combine with --mock)
.build/debug/ClaudeUsageBar --check-token          # token state only, never prints the token
.build/debug/ClaudeUsageBar --render-icons /tmp/i  # PNGs of every icon + sheet.png, to eyeball SVG rendering
./Scripts/bundle.sh                                # release build -> build/ClaudeUsageBar.app (ad-hoc signed)
```

Reinstall after a change (same path, so the Launch at Login item keeps working):

```bash
pkill -x ClaudeUsageBar; ./Scripts/bundle.sh && ditto build/ClaudeUsageBar.app /Applications/ClaudeUsageBar.app && open /Applications/ClaudeUsageBar.app
```

## Where things live

| Change | File |
|---|---|
| Panel text, layout, Launch at Login toggle | `Sources/ClaudeUsageBar/PopoverView.swift` |
| Menu bar label (`73%`, `73%!`, `?`, `…`), launch arguments | `Sources/ClaudeUsageBar/App.swift` |
| Polling loop, backoff application, status notices, wake handling | `Sources/ClaudeUsageBar/UsageStore.swift` |
| Endpoint call, response parsing, row titles, `BackoffPolicy`, User-Agent | `Sources/ClaudeUsageBar/UsageAPI.swift` |
| Token reading and expiry check | `Sources/ClaudeUsageBar/Credentials.swift` |
| Icon step selection, SVG loading, `--render-icons` | `Sources/ClaudeUsageBar/IconProvider.swift` |
| Menu bar icons (SVG, used as-is) | `Resources/icons/` |
| App icon | `Resources/AppIcon.icns` (source: `Resources/app-icon.svg`) |

## Hard constraints (do not break)

- Polling interval is **180 s**. Never shorten it. If 429s become frequent, raise it (300 s) rather than lower it.
- After a 429, wait `max(Retry-After, current backoff)` (300 s doubling to 1800 s). **Make no request at all during backoff**, including manual refresh.
- Never call the API with an expired token (expiry check has a 60 s margin). Expired tokens produce long 429s, not auth errors.
- **Never log, print, store, or commit the token or request headers.** `--check-token` prints only metadata. Do not add debug output of responses that includes headers.
- Never refresh the token with the refresh token. Claude Code owns refreshing; the user runs `claude` once.
- Never run two real-mode instances at once (they share one rate limit). Real API calls are for final integration checks only; use `--mock` and a local fake server for everything else.
- Menu bar SVGs are used exactly as supplied: no recoloring in code, `isTemplate = false`. Icon steps come from scanning the folder, not a hardcoded list.
- `--api-url` must stay restricted to loopback hosts so the token can only go to the real endpoint or localhost.
- **Launch arguments are strict.** Unknown or malformed arguments exit with code 2 (`LaunchOptions.parse`). Keep it that way: a misparsed flag used to fall through to real mode and call the API. When scripting launches, pass each argument as a separate word. In zsh an unquoted `$args` is not word-split, so `"$BIN" $args` sends `--mock 27` as one argument (now an error, previously a silent real-mode start that hit the API several times in a minute).
- UI strings are English.

## Design decisions and why

- **Token via `/usr/bin/security`, not `SecItemCopyMatching`.** Keychain "Always Allow" is bound to the caller's code signature. An ad-hoc signed app changes signature on every build and would re-prompt every time; `security` is always the same caller.
- **Parse with `JSONSerialization`, not `Codable`.** The endpoint is unofficial. Read only needed fields; unknown or missing fields must never crash. `resets_at` has microseconds and an offset, so try the fractional-seconds formatter first, then the plain one. Model-specific limits (`seven_day_opus`/`seven_day_sonnet`, or extra `limits` entries) have only ever been seen as `null`, so that path is untested against real data.
- **A limit whose `resets_at` is in the past counts as fully available** until the next fetch.
- **Swift 5 language mode, `swift-tools-version:5.9`** so Command Line Tools 15 can build it. The code also builds in Swift 6 mode; keep it that way. Two things exist for that: `locateIconDirectory()` is `nonisolated` (Swift 5 mode rejects a main-actor call in a default argument), and the login toggle passes a **closure** to `Binding(set:)`. Passing a method reference there crashes the Swift 6 compiler.
- **`Task.sleep` does not advance while the Mac sleeps**, so on wake the loop is rebuilt from an absolute `nextPollAt`.
- **Login toggle** follows the result of `register()`/`unregister()` and re-reads real status when the panel opens, because status read right after `register()` can lag.
- Icon step: nearest number to the remaining percent; ties go to the lower step.

## Testing

There is no test target. Verification used:

- `--mock` / `--mock-error` and `--render-icons` for UI and icons.
- A local fake HTTP server plus `--api-url http://127.0.0.1:<port>/` to exercise the real polling loop: 200 cadence (>= 180 s), 429 (single request, no retry during backoff), 503, garbage body, refused connection.
- Compiling `UsageAPI.swift` with a small `main.swift` to check parsing against `Fixtures/usage_sample.json` and `BackoffPolicy` sequences.
- Building in both language modes. To check Swift 6: copy the repo somewhere temporary, set `swift-tools-version:6.0`, delete the `swiftLanguageVersions` line, run `swift build`.

Observed once, cause not confirmed: after a burst of accidental real-mode launches (see the launch-arguments constraint above) the menu bar showed the error icon with `?` and recovered on its own within minutes without a restart. That is consistent with a 429 followed by the backoff retry, but the panel notice was not captured, so the 429 path is not proven end to end.

Not verified: real wake-from-sleep behavior, a confirmed 429-then-success recovery, Swift versions below 5.9, Intel Macs, keychain item names when `CLAUDE_CONFIG_DIR` is customized.

## Troubleshooting

- Panel shows `Can't connect (HTTP 200)`: the response had no readable limits, so the format probably changed. Fix `UsageAPI.parse` and refresh the fixture (strip amounts and any identifying data).
- `Token expired` / `Sign in to Claude Code`: run `claude` once in a terminal; check with `--check-token`.
- Menu bar shows only text: icons were not found. In a bundle they are in `Contents/Resources/icons`; in dev runs they are found by walking up from the binary to `Resources/icons`.
- Launch at Login points at an old path after moving the app: quit, install to `/Applications`, then toggle it off and on in the panel.

## Repo and legal notes

- Code is MIT (`LICENSE`). The artwork (`Resources/icons/*.svg`, `AppIcon.icns`, `app-icon.svg`) is excluded and not licensed; see `NOTICE.md`.
- The endpoint is unofficial and using a subscription OAuth token outside Claude Code may violate Anthropic's terms (see the notices in `README.md`). Do not present this as sanctioned, and do not add features that collect, store, or forward tokens.
- The repo is private. Before making it public: settle the terms and artwork questions, and publish from a **fresh repository** (old commit SHAs from before a history rewrite may still be fetchable on the current one).
- Git history was already rewritten once to use the GitHub noreply address; do not rewrite it again. Commit with the noreply address.

# Claude Usage Bar

A small native macOS menu bar app that shows how much of your claude.ai subscription limits is **left** (5-hour session and 7-day weekly).

- **Menu bar:** a Clawd gauge icon that matches the remaining amount, plus the remaining session percentage (e.g. `73%`)
- **Click:** remaining bars for the session, weekly, and per-model weekly limits, time until each resets, your plan (e.g. `Pro`) as a small badge, Refresh Now, Launch at Login, Quit

Every percentage in the app is what is **left**, not what has been used (claude.ai's own usage page shows the used side, so `31% used` there appears as `69%` here).

## Important notices

Read these before using the app.

- **Independent project.** It is not made, endorsed, or supported by Anthropic. "Claude" is a trademark of Anthropic, PBC.
- **Unofficial API.** The app calls `https://api.anthropic.com/api/oauth/usage`, which is not in Anthropic's public documentation. It can change or stop working at any time.
  The app reads only the values it needs and ignores unknown fields, but if the format changes a lot, values may stop showing.
- **Terms of service are not verified.** The app borrows the OAuth token that Claude Code stores in your keychain and uses it outside Claude Code.
  I have not confirmed that Anthropic's terms allow this, and they may not. Read the current terms yourself. **Use this app at your own risk**, including any consequence for your Claude account.
- **Request identity.** To be accepted by the endpoint, the app sends `User-Agent: claude-code/<version>`, the same identifier the Claude Code CLI uses, so its requests look like Claude Code's.
  If you are not comfortable with that, do not use this app.
- **Token handling.** The token is read right before each request, kept only in memory, never written to logs or files, and never refreshed by the app. The relevant code is short: `Credentials.swift` and `UsageAPI.swift`.

## Requirements

- Apple Silicon Mac, macOS 13 or later
- Swift 5.9 or later (Command Line Tools 15+ is enough; Xcode is not required). Tested with Swift 6.3.3; versions below 5.9 were not tried.
  To build in Swift 6 language mode, remove `swiftLanguageVersions: [.v5]` from `Package.swift` and raise `swift-tools-version` to 6.0 (the code builds without errors in both modes).
- **Claude Code installed and signed in with your subscription account.**
  The app has no login of its own. It borrows the OAuth token that Claude Code stores in the macOS keychain (`Claude Code-credentials`),
  and falls back to `~/.claude/.credentials.json` if the keychain read fails.

## Build and run

```bash
./Scripts/bundle.sh
open build/ClaudeUsageBar.app
```

`bundle.sh` runs `swift build -c release`, assembles the `.app`, and ad-hoc signs it (`codesign --sign -`) in one go.
No Dock icon appears (`LSUIElement`).
To run the binary directly during development, use `swift build` and then `.build/debug/ClaudeUsageBar`.

### Keychain prompt on first run

The first time the token is read, a keychain access prompt appears once. Choose **"Always Allow"**.
The token is read through `/usr/bin/security` rather than by the app itself, so rebuilding the ad-hoc signed app does not invalidate the permission.

### Launch at Login

The "Launch at Login" toggle in the panel uses `SMAppService`. Copy the app to `/Applications` before turning it on.

## Behavior

| Item | Value |
|---|---|
| Polling interval | 180 seconds (once right after launch, then every 180 seconds) |
| HTTP 429 | Waits the longer of `Retry-After` and the current backoff. Backoff starts at 300 seconds, doubles on each consecutive 429, and caps at 1800 seconds. Reset on the first success |
| During a 429 backoff | No request is made, including manual refresh |
| Other errors | Retries on the normal 180-second cycle and keeps showing the last successful value |
| Token expired or missing | No API call; only re-reads the token every 180 seconds |
| Wake from sleep | Fetches right away if the scheduled time has passed |

- The token is re-read right before every request and is never written to logs or files. The app does not refresh the token with the refresh token.
- If the token expires, run `claude` once in a terminal and Claude Code will refresh it.
- The plan badge comes from the `subscriptionType` field of the same keychain entry. It is undocumented, so the badge is simply hidden when the field is missing or unreadable. It appears after the first successful token read.
- Requests share the same rate limit, so do not run more than one instance (or other widgets using the same API) at the same time.

### Menu bar states

| State | Display |
|---|---|
| Loading | Dimmed icon + `…` |
| OK | Remaining icon + `73%` |
| Rate limited, offline, or other error | Last value kept + `!` after it (e.g. `73%!`) |
| Token expired, sign-in needed, or no value | Error icon + `?` |

A limit whose `resets_at` is already in the past is treated as fully available (0% used) until the next fetch.

## Replacing the menu bar icons

The icons are the SVGs in `Resources/icons/`, used as they are (the code never recolors or reshapes them).

- `icon-<number>.svg`: one icon per remaining-amount step. The file whose number is **closest** to the remaining percentage is shown (ties go to the lower one). The folder is scanned, so adding or removing steps needs no code change.
- `icon-error.svg`: the error-state icon. If it is missing, the last icon is used at 40% alpha.
- Height is fixed at 18 pt in the menu bar and the aspect ratio follows the SVG's viewBox.

After changing files, rebuild with `./Scripts/bundle.sh`. AppKit may not draw some SVG features (filters, CSS styles, masks), so check the rendering:

```bash
.build/debug/ClaudeUsageBar --render-icons /tmp/icons   # saves every icon as a PNG (512 px tall) plus a contact sheet, sheet.png
```

## App icon

The app icon shown in Finder and Login Items is `Resources/AppIcon.icns` (referenced by `CFBundleIconFile` in `Info.plist`). It is separate from the menu bar icons.
The source is `Resources/app-icon.svg`. Build an `iconset` from PNGs of each size (16 to 1024 px) and convert it with `iconutil -c icns <name>.iconset -o Resources/AppIcon.icns`, then rebuild with `./Scripts/bundle.sh`.

## Test launch arguments

| Argument | Description |
|---|---|
| `--mock <used%>` | Makes no API call and shows the given session **used** percentage (`--mock 27` shows 73% left) |
| `--mock-error <expired\|login\|ratelimit\|offline>` | Shows each error state. Combine with `--mock` to see the case where the last value is kept |
| `--render-icons <dir>` | Renders the icons with AppKit and saves them as PNGs |
| `--check-token` | Prints only the token state (valid/expired/not found, source, plan, time left), never the token itself |
| `--api-url <url>` | Points the request at a local server (`127.0.0.1`, `localhost`, `::1`). For testing |
| `--help` | Prints the usage |

Unknown or malformed arguments (a misspelled flag, a missing value, `--api-url` pointing anywhere but loopback) print an error and exit with code 2 instead of starting the app, so a typo can never silently start real mode and call the API. When scripting launches, pass each argument as a separate word (`--mock 27`, not `"--mock 27"`).

`Fixtures/usage_sample.json` is a sample of a real response reduced to the structure needed for parsing (amounts and usage history removed).

## Memory

`ps -o rss=`: **72-77 MB** in mock mode and **about 81-88 MB** in real mode (after the first fetch, panel closed). This misses the original 30 MB goal.
The process's physical memory (`footprint`, `vmmap -summary`) is about 14 MB in mock mode and about 16-26 MB in real mode. RSS looks large because it includes shared pages of system frameworks such as SwiftUI and AppKit.
When the panel is first opened, physical memory briefly rises to around 100 MB and returns to the 20 MB range after it closes (measured: peak about 102 MB, then 26 MB, stable over 30 seconds).

## Project layout

```
Package.swift
Sources/ClaudeUsageBar/
  App.swift            @main, MenuBarExtra, launch arguments, menu bar label
  UsageStore.swift     state, polling loop, backoff handling
  UsageAPI.swift       endpoint call, response parsing, backoff policy, User-Agent
  Credentials.swift    token reading, expiry check
  IconProvider.swift   picks/loads/caches the SVG for the remaining amount, --render-icons
  PopoverView.swift    the panel shown on click
Resources/Info.plist, Resources/icons/ (menu bar), Resources/AppIcon.icns, Resources/app-icon.svg (app icon)
Fixtures/usage_sample.json
Scripts/bundle.sh
```

## License

The source code is released under the [MIT License](LICENSE).

The artwork is **not** covered by that license: the Clawd menu bar icons (`Resources/icons/`) and the app icon (`AppIcon.icns`, `app-icon.svg`) depict the Claude Code mascot, which belongs to Anthropic, PBC.
They are included only so the app runs for personal use. If you redistribute the app or a fork, replace them with your own artwork. See [NOTICE.md](NOTICE.md).

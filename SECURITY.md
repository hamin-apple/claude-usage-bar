# Security

## Reporting a problem

Report security problems privately through GitHub: open the repository's **Security** tab and choose **Report a vulnerability**. That thread is visible only to you and the maintainer.

Do not open a public issue for a security problem, and do not report it through a pull request.

This is a personal project with one maintainer and no service behind it. There is no response-time guarantee, and there is no bug bounty.

## Never include a token

The app uses the OAuth access token that Claude Code stores in your keychain. That token grants access to your Claude account.

- Never paste a token, a `Claude Code-credentials` keychain entry, a `~/.claude/.credentials.json` file, or an `Authorization` header into an issue, a pull request, a report, or a screenshot.
- The app is built so this is hard to do by accident: it never writes the token to logs or files, and `--check-token` prints only metadata (state, source, plan, time left, token length). Use that output instead of the token itself.
- If you think a token has been exposed, sign out and back in with `claude` so Claude Code issues a new one. This app cannot refresh or revoke tokens.

## What is in scope

- The app sending the token anywhere other than `https://api.anthropic.com/api/oauth/usage` (or a loopback address given with `--api-url`)
- The token being written to a log, a file, the clipboard, or standard output
- A launch argument or installer path that starts the app in real mode when it should not, or that runs code from an unexpected place
- Anything in `Scripts/npx-install.sh` that writes outside `/Applications/ClaudeUsageBar.app` or runs with unexpected privileges

## What is not a vulnerability here

- **Using an unofficial endpoint and Claude Code's token outside Claude Code.** This is what the app does by design, and the risk is described in the README's Important notices. Anthropic's terms may not allow it.
- **The keychain prompt on first run**, and the "Always Allow" choice it offers.
- **Rate limiting (HTTP 429)** from running several clients against the same limit.
- Reports about Anthropic's own services. Send those to Anthropic, not here.

## Supported versions

Only the latest release and the current `main` are looked at. There are no backports.

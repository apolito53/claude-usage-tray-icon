# Claude Usage Tray

A tiny Ubuntu AppIndicator that keeps Claude subscription usage visible without
opening Claude Code's `/usage` screen.

The panel icon shows the percentage remaining in the current five-hour window.
Its menu shows:

- current-session usage and local reset time;
- seven-day all-model usage and local reset time;
- any Opus, Sonnet, or overage-specific weekly windows returned by the account;
- online, stale, or offline status;
- manual refresh, startup, logs, and exit controls.

Usage above 50% remaining is green, 21-50% is amber, and 20% or less is red. If
a refresh fails after a successful reading, the last value remains visible with
an offline badge instead of disappearing.

## How it works

Claude Code documents subscription percentages in its interactive `/usage`
screen and in the JSON supplied to custom status-line scripts, but it does not
currently expose a supported non-interactive `claude usage --json` command.
This tray calls the same read-only endpoint currently used by Claude Code:

```text
GET https://api.anthropic.com/api/oauth/usage
```

The access token is read fresh for each request from the credential file
managed by Claude Code (`~/.claude/.credentials.json`, or
`$CLAUDE_CONFIG_DIR/.credentials.json`). `CLAUDE_CODE_OAUTH_TOKEN` is also
honored when present.

The tray:

- keeps the token in memory only;
- never logs it or an endpoint response body;
- never writes or refreshes Claude's credential;
- never sends a prompt or makes a model inference request;
- polls every five minutes by default;
- honors `Retry-After` and backs off for at least 10 minutes after HTTP 429.

The endpoint is an internal Claude Code dependency, not a documented public
Anthropic API. A future Claude Code release can rename or reshape it. The tray
fails closed when the response no longer matches the expected schema.

Subscription windows are available only for eligible Claude.ai OAuth plans.
API-key, Bedrock, Vertex, and Foundry authentication do not expose this quota.
See Anthropic's [authentication documentation](https://code.claude.com/docs/en/team)
and [status-line field reference](https://code.claude.com/docs/en/statusline).

## Requirements

- Ubuntu or a compatible Linux desktop with GTK 3
- Python 3.8 or newer
- `python3-gi`
- AppIndicator3 or AyatanaAppIndicator3
- Claude Code signed in with an eligible Claude.ai subscription

On Ubuntu 20.04, install the same indicator dependencies used by the Codex tray:

```bash
sudo apt install python3-gi gir1.2-appindicator3-0.1
```

On distributions packaging Ayatana AppIndicator instead:

```bash
sudo apt install python3-gi gir1.2-ayatanaappindicator3-0.1
```

## Install

```bash
git clone git@github.com:apolito53/claude-usage-tray-icon.git
cd claude-usage-tray-icon
./install.sh
```

The installer copies the launcher to `~/.local/bin/claude-usage-tray`, creates
an application entry, enables GNOME startup, and launches the tray. Use
`./install.sh --no-startup` to install without autostart.

Run a one-shot subscription check without starting the tray:

```bash
./linux/claude_usage_tray.py --check
```

Override the five-minute refresh interval with a value of at least 60 seconds:

```bash
CLAUDE_USAGE_TRAY_REFRESH_SECONDS=900 claude-usage-tray
```

## Diagnostics and privacy

Private rotating logs live at:

```text
${XDG_STATE_HOME:-~/.local/state}/claude-usage-tray/usage-tray.log
```

The log directory is mode `0700` and the log is mode `0600`. Logs include only
window identifiers, percentages, and sanitized error summaries. OAuth tokens
and HTTP response bodies are deliberately excluded.

If a saved token expires, open Claude Code so it can refresh its own credential,
then select **Refresh now**. This app intentionally does not implement OAuth
refresh-token rotation.

## Testing

```bash
python3 -m unittest discover -s tests -v
bash -n install.sh uninstall.sh
python3 -m py_compile linux/claude_usage_tray.py
```

The parser, credential boundary, HTTP behavior, rate-limit backoff, icon, and
desktop integration are covered using mock responses. This development machine
currently uses Vertex authentication rather than Claude.ai subscription OAuth,
so the successful live subscription response remains intentionally unverified.
The local non-subscription failure path can still be tested without making a
model request.

## Uninstall

```bash
./uninstall.sh
```

Pass `--purge-logs` to also remove diagnostic logs.

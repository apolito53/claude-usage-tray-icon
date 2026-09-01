#!/usr/bin/env python3
"""Ubuntu tray indicator for Claude subscription usage.

Claude Code does not currently expose a non-interactive ``usage`` command.
This client reads the OAuth credential managed by Claude Code and calls the
same read-only usage endpoint used by Claude Code's ``/usage`` screen. It never
sends a model prompt and never writes to Claude's credential store.
"""

import argparse
import dataclasses
import datetime as dt
import email.utils
import fcntl
import html
import json
import logging
from logging.handlers import RotatingFileHandler
import math
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import threading
from typing import Any, Mapping, Optional, Sequence, TextIO, Tuple
import urllib.error
import urllib.request


APP_ID = "claude-usage-tray"
APP_NAME = "Claude Usage Tray"
APP_VERSION = "0.1.0"
ICON_LAYOUT_VERSION = 1
USAGE_ENDPOINT = "https://api.anthropic.com/api/oauth/usage"
OAUTH_BETA = "oauth-2025-04-20"
RESPONSE_TIMEOUT_SECONDS = 12
MAX_RESPONSE_BYTES = 256 * 1024
DEFAULT_REFRESH_INTERVAL_SECONDS = 5 * 60
REFRESH_INTERVAL_VARIABLE = "CLAUDE_USAGE_TRAY_REFRESH_SECONDS"
OFFLINE_RETRY_INTERVALS = (60, 2 * 60, 5 * 60)
RATE_LIMIT_RETRY_INTERVALS = (10 * 60, 30 * 60, 60 * 60)

WINDOW_LABELS = (
    ("five_hour", "Current session (5 hours)"),
    ("seven_day", "Current week (all models)"),
    ("seven_day_opus", "Current week (Opus)"),
    ("seven_day_sonnet", "Current week (Sonnet)"),
    ("seven_day_overage_included", "Current week (overage included)"),
)


class ClaudeUsageError(RuntimeError):
    """A user-facing failure at the Claude usage boundary."""

    def __init__(
        self,
        message: str,
        retry_after_seconds: Optional[int] = None,
        rate_limited: bool = False,
    ) -> None:
        super().__init__(message)
        self.retry_after_seconds = retry_after_seconds
        self.rate_limited = rate_limited


@dataclasses.dataclass(frozen=True)
class UsageWindow:
    key: str
    label: str
    used_percent: int
    remaining_percent: int
    reset_at_local: Optional[dt.datetime]


@dataclasses.dataclass(frozen=True)
class UsageSnapshot:
    windows: Tuple[UsageWindow, ...]
    checked_at_local: dt.datetime

    def window(self, key: str) -> Optional[UsageWindow]:
        return next((window for window in self.windows if window.key == key), None)

    @property
    def primary(self) -> UsageWindow:
        return self.window("five_hour") or self.windows[0]


def _xdg_path(variable: str, fallback: Path) -> Path:
    configured = os.environ.get(variable)
    return Path(configured).expanduser() if configured else fallback


def cache_directory() -> Path:
    return _xdg_path("XDG_CACHE_HOME", Path.home() / ".cache") / APP_ID


def state_directory() -> Path:
    return _xdg_path("XDG_STATE_HOME", Path.home() / ".local" / "state") / APP_ID


def autostart_path() -> Path:
    return (
        _xdg_path("XDG_CONFIG_HOME", Path.home() / ".config")
        / "autostart"
        / (APP_ID + ".desktop")
    )


def claude_config_directory(
    env: Optional[Mapping[str, str]] = None,
    user_home: Optional[Path] = None,
) -> Path:
    env = os.environ if env is None else env
    configured = env.get("CLAUDE_CONFIG_DIR")
    if configured:
        return Path(configured).expanduser()
    return (user_home or Path.home()) / ".claude"


def credentials_path(
    env: Optional[Mapping[str, str]] = None,
    user_home: Optional[Path] = None,
) -> Path:
    return claude_config_directory(env, user_home) / ".credentials.json"


def refresh_interval_seconds(env: Optional[Mapping[str, str]] = None) -> int:
    env = os.environ if env is None else env
    configured = env.get(REFRESH_INTERVAL_VARIABLE)
    if configured is None:
        return DEFAULT_REFRESH_INTERVAL_SECONDS
    try:
        return max(60, int(configured))
    except ValueError:
        return DEFAULT_REFRESH_INTERVAL_SECONDS


def load_oauth_token(
    env: Optional[Mapping[str, str]] = None,
    user_home: Optional[Path] = None,
) -> str:
    """Read a Claude subscription bearer token without modifying its store."""

    env = os.environ if env is None else env
    supplied = env.get("CLAUDE_CODE_OAUTH_TOKEN", "").strip()
    if supplied:
        return supplied

    path = credentials_path(env, user_home)
    try:
        mode = stat.S_IMODE(path.stat().st_mode)
        if mode & 0o077:
            raise ClaudeUsageError(
                "Claude credential file permissions are too broad at {}. "
                "Claude Code normally keeps this file at mode 0600.".format(path)
            )
        document = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exception:
        raise ClaudeUsageError(
            "No Claude.ai OAuth credentials were found at {}. Subscription usage "
            "requires Claude Code to be signed in with a Claude.ai plan; API, "
            "Bedrock, Vertex, and Foundry logins do not expose this quota.".format(path)
        ) from exception
    except json.JSONDecodeError as exception:
        raise ClaudeUsageError(
            "Claude's credential file is not valid JSON. Run `claude doctor` before retrying."
        ) from exception
    except OSError as exception:
        raise ClaudeUsageError(
            "Could not read Claude's credential file: " + str(exception)
        ) from exception

    oauth = document.get("claudeAiOauth") if isinstance(document, dict) else None
    token = oauth.get("accessToken") if isinstance(oauth, dict) else None
    if not isinstance(token, str) or not token.strip():
        raise ClaudeUsageError(
            "Claude Code is not signed in with Claude.ai subscription OAuth. "
            "API, Bedrock, Vertex, and Foundry authentication do not have the "
            "5-hour or weekly subscription quota shown by `/usage`."
        )
    return token.strip()


def _local_time(value: Any) -> Optional[dt.datetime]:
    if value is None:
        return None
    try:
        if isinstance(value, bool):
            raise ValueError
        if isinstance(value, (int, float)):
            parsed = dt.datetime.fromtimestamp(float(value), tz=dt.timezone.utc)
        elif isinstance(value, str):
            normalized = value.strip()
            if not normalized:
                return None
            if normalized.endswith("Z"):
                normalized = normalized[:-1] + "+00:00"
            parsed = dt.datetime.fromisoformat(normalized)
            if parsed.tzinfo is None:
                parsed = parsed.replace(tzinfo=dt.timezone.utc)
        else:
            raise ValueError
        return parsed.astimezone()
    except (OverflowError, OSError, ValueError):
        return None


def _percentage(value: Any, key: str) -> int:
    if (
        isinstance(value, bool)
        or not isinstance(value, (int, float))
        or not math.isfinite(float(value))
    ):
        raise ClaudeUsageError(
            "Claude usage window '{}' omitted utilization.".format(key)
        )
    return max(0, min(100, int(float(value) + 0.5)))


def parse_usage_response(response: Mapping[str, Any]) -> UsageSnapshot:
    if not isinstance(response, Mapping):
        raise ClaudeUsageError("Claude returned an unexpected usage response.")

    windows = []
    for key, label in WINDOW_LABELS:
        raw = response.get(key)
        if raw is None:
            continue
        if not isinstance(raw, Mapping):
            raise ClaudeUsageError(
                "Claude usage window '{}' had an unexpected shape.".format(key)
            )
        utilization = raw.get("utilization", raw.get("used_percentage"))
        used_percent = _percentage(utilization, key)
        windows.append(
            UsageWindow(
                key=key,
                label=label,
                used_percent=used_percent,
                remaining_percent=100 - used_percent,
                reset_at_local=_local_time(raw.get("resets_at")),
            )
        )

    if not windows:
        raise ClaudeUsageError(
            "Claude returned no active subscription usage windows. This login may "
            "not have a Pro, Max, Team, or Enterprise quota."
        )
    return UsageSnapshot(tuple(windows), dt.datetime.now().astimezone())


def _retry_after_seconds(value: Optional[str]) -> Optional[int]:
    if not value:
        return None
    try:
        return max(0, int(float(value)))
    except ValueError:
        try:
            retry_at = email.utils.parsedate_to_datetime(value)
            if retry_at.tzinfo is None:
                retry_at = retry_at.replace(tzinfo=dt.timezone.utc)
            return max(
                0,
                int(
                    (retry_at - dt.datetime.now(dt.timezone.utc)).total_seconds()
                ),
            )
        except (TypeError, ValueError, OverflowError):
            return None


class ClaudeUsageClient:
    def __init__(self) -> None:
        self._cancelled = False
        self._lock = threading.Lock()

    def get_usage(self) -> UsageSnapshot:
        with self._lock:
            if self._cancelled:
                raise ClaudeUsageError("Claude usage refresh was cancelled.")

        token = load_oauth_token()
        request = urllib.request.Request(
            USAGE_ENDPOINT,
            headers={
                "Accept": "application/json",
                "Authorization": "Bearer " + token,
                "anthropic-beta": OAUTH_BETA,
                "User-Agent": "{}/{}".format(APP_ID, APP_VERSION),
            },
            method="GET",
        )
        try:
            with urllib.request.urlopen(
                request,
                timeout=RESPONSE_TIMEOUT_SECONDS,
            ) as response:
                payload = response.read(MAX_RESPONSE_BYTES + 1)
        except urllib.error.HTTPError as exception:
            if exception.code == 401:
                message = (
                    "Claude rejected the saved OAuth token. Open Claude Code and run "
                    "`/login`, then retry."
                )
            elif exception.code == 403:
                message = (
                    "This Claude login is not allowed to read subscription usage."
                )
            elif exception.code == 429:
                retry_header = (
                    exception.headers.get("Retry-After")
                    if exception.headers is not None
                    else None
                )
                raise ClaudeUsageError(
                    "Claude temporarily rate-limited usage checks.",
                    retry_after_seconds=_retry_after_seconds(retry_header),
                    rate_limited=True,
                ) from exception
            else:
                message = "Claude usage request failed with HTTP {}.".format(
                    exception.code
                )
            raise ClaudeUsageError(message) from exception
        except urllib.error.URLError as exception:
            reason = str(exception.reason)
            if len(reason) > 160:
                reason = reason[:157] + "…"
            raise ClaudeUsageError(
                "Could not reach Claude's usage service: " + reason
            ) from exception
        except (OSError, TimeoutError) as exception:
            raise ClaudeUsageError(
                "Could not reach Claude's usage service: " + str(exception)
            ) from exception

        if len(payload) > MAX_RESPONSE_BYTES:
            raise ClaudeUsageError(
                "Claude's usage response was unexpectedly large."
            )
        try:
            document = json.loads(payload.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exception:
            raise ClaudeUsageError(
                "Claude returned an unreadable usage response."
            ) from exception
        return parse_usage_response(document)

    def cancel(self) -> None:
        with self._lock:
            self._cancelled = True


def configure_logging() -> logging.Logger:
    log_root = state_directory()
    log_root.mkdir(parents=True, exist_ok=True)
    log_root.chmod(0o700)
    log_path = log_root / "usage-tray.log"
    logger = logging.getLogger(APP_ID)
    logger.setLevel(logging.INFO)
    if not logger.handlers:
        handler = RotatingFileHandler(
            str(log_path),
            maxBytes=1024 * 1024,
            backupCount=1,
            encoding="utf-8",
        )
        handler.setFormatter(
            logging.Formatter("%(asctime)s [%(levelname)s] %(message)s")
        )
        logger.addHandler(handler)
    log_path.chmod(0o600)
    return logger


def _desktop_exec_path(executable_path: Path) -> str:
    escaped = str(executable_path).replace("\\", "\\\\").replace('"', '\\"')
    escaped = escaped.replace("`", "\\`").replace("$", "\\$")
    return '"' + escaped + '"'


def startup_is_enabled() -> bool:
    path = autostart_path()
    if not path.is_file():
        return False
    try:
        contents = path.read_text(encoding="utf-8")
    except OSError:
        return False
    return "X-GNOME-Autostart-enabled=false" not in contents


def set_startup_enabled(enabled: bool, executable_path: Path) -> None:
    path = autostart_path()
    if not enabled:
        try:
            path.unlink()
        except FileNotFoundError:
            pass
        return

    path.parent.mkdir(parents=True, exist_ok=True)
    contents = "\n".join(
        (
            "[Desktop Entry]",
            "Type=Application",
            "Name=" + APP_NAME,
            "Comment=Show remaining Claude subscription usage in the system tray",
            "Exec=" + _desktop_exec_path(executable_path),
            "Terminal=false",
            "X-GNOME-Autostart-enabled=true",
            "",
        )
    )
    temporary = path.with_suffix(".desktop.tmp")
    temporary.write_text(contents, encoding="utf-8")
    temporary.replace(path)


class SingleInstanceLock:
    def __init__(self) -> None:
        self._stream: Optional[TextIO] = None
        self.path = cache_directory() / (APP_ID + ".pid")

    def acquire(self) -> bool:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        stream = self.path.open("a+", encoding="ascii")
        try:
            fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            stream.close()
            return False
        stream.seek(0)
        stream.truncate()
        stream.write(str(os.getpid()) + "\n")
        stream.flush()
        self._stream = stream
        return True

    def release(self) -> None:
        if self._stream is None:
            return
        try:
            self.path.unlink()
        except FileNotFoundError:
            pass
        fcntl.flock(self._stream.fileno(), fcntl.LOCK_UN)
        self._stream.close()
        self._stream = None


def write_status_icon(text: str, color: str, offline: bool) -> Tuple[Path, str]:
    icon_root = cache_directory() / "icons"
    icon_root.mkdir(parents=True, exist_ok=True)
    safe_text = (
        "".join(character for character in text if character.isalnum())
        or "status"
    )
    state = "offline" if offline else "online"
    icon_name = "claude-usage-v{}-{}-{}-{}".format(
        ICON_LAYOUT_VERSION,
        safe_text,
        color.lstrip("#"),
        state,
    )
    icon_path = icon_root / (icon_name + ".svg")
    if not icon_path.exists():
        font_size = 25 if len(text) >= 3 else 38 if len(text) == 2 else 42
        badge = ""
        if offline:
            badge = (
                '<circle cx="55" cy="8" r="7" fill="#cf222e" '
                'stroke="#ffffff" stroke-width="2.5"/>'
            )
        baseline_y = 31 + (font_size * 0.35)
        svg = """<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64">
  <circle cx="32" cy="33" r="30" fill="#000000" fill-opacity="0.35"/>
  <circle cx="32" cy="32" r="30.5" fill="{color}" stroke="#ffffff" stroke-opacity="0.86" stroke-width="1.5"/>
  <text x="32" y="{baseline_y:.2f}" fill="#ffffff" font-family="DejaVu Sans, sans-serif" font-size="{font_size}" font-weight="bold" text-anchor="middle">{text}</text>
  {badge}
</svg>
""".format(
            color=color,
            font_size=font_size,
            baseline_y=baseline_y,
            text=html.escape(text),
            badge=badge,
        )
        temporary = icon_path.with_suffix(".svg.tmp")
        temporary.write_text(svg, encoding="utf-8")
        temporary.replace(icon_path)
    return icon_root, icon_name


def _load_indicator_dependencies():
    try:
        import gi

        gi.require_version("Gtk", "3.0")
        from gi.repository import GLib, Gtk

        try:
            gi.require_version("AyatanaAppIndicator3", "0.1")
            from gi.repository import AyatanaAppIndicator3 as AppIndicator
        except (ImportError, ValueError):
            gi.require_version("AppIndicator3", "0.1")
            from gi.repository import AppIndicator3 as AppIndicator
    except (ImportError, ValueError) as exception:
        raise ClaudeUsageError(
            "GTK AppIndicator support is missing. Install python3-gi and either "
            "gir1.2-ayatanaappindicator3-0.1 or gir1.2-appindicator3-0.1."
        ) from exception
    return GLib, Gtk, AppIndicator


class TrayApplication:
    def __init__(self, executable_path: Path) -> None:
        self.GLib, self.Gtk, self.AppIndicator = _load_indicator_dependencies()
        self.executable_path = executable_path
        self.logger = configure_logging()
        self.client = ClaudeUsageClient()
        self.latest_snapshot: Optional[UsageSnapshot] = None
        self.consecutive_failures = 0
        self.rate_limit_failures = 0
        self.refresh_in_progress = False
        self.timer_source: Optional[int] = None
        self.exiting = False
        self.changing_startup = False

        icon_root, icon_name = write_status_icon("?", "#6e7781", False)
        self.indicator = self.AppIndicator.Indicator.new(
            APP_ID,
            icon_name,
            self.AppIndicator.IndicatorCategory.APPLICATION_STATUS,
        )
        self.indicator.set_icon_theme_path(str(icon_root))
        self.indicator.set_status(self.AppIndicator.IndicatorStatus.ACTIVE)
        if hasattr(self.indicator, "set_title"):
            self.indicator.set_title(APP_NAME)

        self.menu = self.Gtk.Menu()
        self.summary_item = self._disabled_item("Claude usage: loading…")
        self.session_reset_item = self._disabled_item(
            "Session reset: loading…"
        )
        self.weekly_item = self._disabled_item("Weekly usage: loading…")
        self.weekly_reset_item = self._disabled_item("Weekly reset: loading…")
        self.all_limits_item = self.Gtk.MenuItem(label="All usage windows")
        self.all_limits_item.set_sensitive(False)
        self.status_item = self._disabled_item("Connection: loading…")
        for item in (
            self.summary_item,
            self.session_reset_item,
            self.weekly_item,
            self.weekly_reset_item,
            self.all_limits_item,
            self.status_item,
        ):
            self.menu.append(item)
        self.menu.append(self.Gtk.SeparatorMenuItem())

        self.refresh_item = self.Gtk.MenuItem(label="Refresh now")
        self.refresh_item.connect("activate", lambda _item: self.refresh())
        self.menu.append(self.refresh_item)

        self.startup_item = self.Gtk.CheckMenuItem(label="Start with Ubuntu")
        self.startup_item.set_active(startup_is_enabled())
        self.startup_item.connect("toggled", self._toggle_startup)
        self.menu.append(self.startup_item)

        logs_item = self.Gtk.MenuItem(label="Open diagnostic logs")
        logs_item.connect("activate", self._open_logs)
        self.menu.append(logs_item)
        self.menu.append(self.Gtk.SeparatorMenuItem())

        exit_item = self.Gtk.MenuItem(label="Exit")
        exit_item.connect("activate", lambda _item: self.exit())
        self.menu.append(exit_item)

        self.menu.show_all()
        self.indicator.set_menu(self.menu)
        self._schedule_refresh(0.25)

    def _disabled_item(self, label: str):
        item = self.Gtk.MenuItem(label=label)
        item.set_sensitive(False)
        return item

    def run(self) -> None:
        self.logger.info("%s %s starting on Linux.", APP_NAME, APP_VERSION)
        self.Gtk.main()

    def refresh(self) -> None:
        if self.refresh_in_progress or self.exiting:
            return
        self.refresh_in_progress = True
        self.refresh_item.set_sensitive(False)
        if self.latest_snapshot is None:
            self.summary_item.set_label("Claude usage: refreshing…")
            self.status_item.set_label("Connecting…")
        else:
            self.summary_item.set_label(
                self._format_window(self.latest_snapshot.primary)
                + " - checking…"
            )
            self.status_item.set_label("Checking connection…")
        threading.Thread(target=self._refresh_worker, daemon=True).start()

    def _refresh_worker(self) -> None:
        try:
            snapshot = self.client.get_usage()
            self.GLib.idle_add(self._finish_refresh, snapshot, None)
        except BaseException as exception:
            self.GLib.idle_add(self._finish_refresh, None, exception)

    def _finish_refresh(
        self,
        snapshot: Optional[UsageSnapshot],
        exception: Optional[BaseException],
    ) -> bool:
        if self.exiting:
            return False
        self.refresh_in_progress = False
        self.refresh_item.set_sensitive(True)
        if exception is None and snapshot is not None:
            self.latest_snapshot = snapshot
            self.consecutive_failures = 0
            self.rate_limit_failures = 0
            self._apply_snapshot(snapshot)
            self.logger.info(
                "Usage refreshed: %s.",
                ", ".join(
                    "{}={}%% used".format(window.key, window.used_percent)
                    for window in snapshot.windows
                ),
            )
            self._schedule_refresh(refresh_interval_seconds())
        else:
            error = exception or ClaudeUsageError("Unknown refresh failure.")
            self.consecutive_failures += 1
            self._apply_error(error)
            self.logger.error("Usage refresh failed: %s", error)
            self._schedule_refresh(self._retry_delay(error))
        return False

    def _retry_delay(self, exception: BaseException) -> int:
        if isinstance(exception, ClaudeUsageError) and exception.rate_limited:
            index = min(
                self.rate_limit_failures,
                len(RATE_LIMIT_RETRY_INTERVALS) - 1,
            )
            self.rate_limit_failures += 1
            server_delay = exception.retry_after_seconds or 0
            return max(server_delay, RATE_LIMIT_RETRY_INTERVALS[index])
        index = min(
            self.consecutive_failures - 1,
            len(OFFLINE_RETRY_INTERVALS) - 1,
        )
        return OFFLINE_RETRY_INTERVALS[index]

    def _apply_snapshot(self, snapshot: UsageSnapshot) -> None:
        session = snapshot.window("five_hour") or snapshot.primary
        weekly = snapshot.window("seven_day")
        self.summary_item.set_label(self._format_window(session))
        self.session_reset_item.set_label(
            self._format_reset("Session resets", session.reset_at_local)
        )
        if weekly:
            self.weekly_item.set_label(self._format_window(weekly))
            self.weekly_reset_item.set_label(
                self._format_reset("Week resets", weekly.reset_at_local)
            )
        else:
            self.weekly_item.set_label("Weekly usage unavailable")
            self.weekly_reset_item.set_label("Weekly reset unavailable")
        self._apply_all_limits(snapshot)
        self.status_item.set_label(
            "Online - updated "
            + snapshot.checked_at_local.strftime("%-I:%M:%S %p")
        )
        self._replace_icon(
            str(session.remaining_percent),
            self._usage_color(session.remaining_percent),
            False,
        )

    def _apply_error(self, exception: BaseException) -> None:
        if self.latest_snapshot is not None:
            snapshot = self.latest_snapshot
            self.summary_item.set_label(
                self._format_window(snapshot.primary) + " - STALE"
            )
            self.status_item.set_label(
                "OFFLINE - showing "
                + snapshot.checked_at_local.strftime("%-I:%M:%S %p")
                + " reading"
            )
            self._replace_icon(
                str(snapshot.primary.remaining_percent),
                self._usage_color(snapshot.primary.remaining_percent),
                True,
            )
            return

        self.summary_item.set_label("Claude subscription usage unavailable")
        message = str(exception)
        self.session_reset_item.set_label(
            message if len(message) <= 100 else message[:97] + "…"
        )
        self.weekly_item.set_label("Weekly usage unavailable")
        self.weekly_reset_item.set_label("Weekly reset unavailable")
        self.all_limits_item.set_sensitive(False)
        self.status_item.set_label(
            "OFFLINE - last attempt "
            + dt.datetime.now().strftime("%-I:%M:%S %p")
        )
        self._replace_icon("!", "#cf222e", False)

    def _apply_all_limits(self, snapshot: UsageSnapshot) -> None:
        old = self.all_limits_item.get_submenu()
        if old is not None:
            self.all_limits_item.set_submenu(None)
            old.destroy()
        submenu = self.Gtk.Menu()
        for window in snapshot.windows:
            submenu.append(self._disabled_item(self._format_window(window)))
            submenu.append(
                self._disabled_item(
                    self._format_reset("Resets", window.reset_at_local)
                )
            )
        submenu.show_all()
        self.all_limits_item.set_submenu(submenu)
        self.all_limits_item.set_sensitive(True)

    def _replace_icon(self, text: str, color: str, offline: bool) -> None:
        icon_root, icon_name = write_status_icon(text, color, offline)
        self.indicator.set_icon_theme_path(str(icon_root))
        description = "Claude usage " + text
        if text.isdigit():
            description += " percent remaining"
        if offline:
            description += ", offline"
        self.indicator.set_icon_full(icon_name, description)

    def _schedule_refresh(self, delay_seconds: float) -> None:
        if self.timer_source is not None:
            try:
                self.GLib.source_remove(self.timer_source)
            except self.GLib.Error:
                pass
        self.timer_source = self.GLib.timeout_add(
            max(1, int(delay_seconds * 1000)),
            self._on_timer,
        )

    def _on_timer(self) -> bool:
        self.timer_source = None
        self.refresh()
        return False

    def _toggle_startup(self, item) -> None:
        if self.changing_startup:
            return
        requested = item.get_active()
        try:
            set_startup_enabled(requested, self.executable_path)
            self.logger.info(
                "Start with Ubuntu set to %s.",
                "on" if requested else "off",
            )
        except OSError as exception:
            self.logger.error(
                "Could not change startup registration: %s", exception
            )
            self.changing_startup = True
            item.set_active(not requested)
            self.changing_startup = False
            self.status_item.set_label("Startup setting failed: " + str(exception))

    def _open_logs(self, _item) -> None:
        log_root = state_directory()
        log_root.mkdir(parents=True, exist_ok=True)
        try:
            subprocess.Popen(
                ["xdg-open", str(log_root)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
        except OSError as exception:
            self.logger.error(
                "Could not open the diagnostic log folder: %s", exception
            )
            self.status_item.set_label("Could not open logs: " + str(exception))

    def exit(self) -> None:
        if self.exiting:
            return
        self.exiting = True
        if self.timer_source is not None:
            self.GLib.source_remove(self.timer_source)
            self.timer_source = None
        self.client.cancel()
        self.indicator.set_status(self.AppIndicator.IndicatorStatus.PASSIVE)
        self.logger.info("%s exiting.", APP_NAME)
        self.Gtk.main_quit()

    @staticmethod
    def _format_window(window: UsageWindow) -> str:
        return "{}: {}% left ({}% used)".format(
            window.label,
            window.remaining_percent,
            window.used_percent,
        )

    @staticmethod
    def _format_reset(prefix: str, value: Optional[dt.datetime]) -> str:
        if value is None:
            return prefix + ": unavailable"
        return prefix + " " + value.strftime("%a, %b %-d at %-I:%M %p")

    @staticmethod
    def _usage_color(remaining_percent: int) -> str:
        if remaining_percent > 50:
            return "#2da44e"
        if remaining_percent > 20:
            return "#d29922"
        return "#cf222e"


def check_dependencies() -> None:
    _load_indicator_dependencies()


def print_live_usage() -> int:
    try:
        snapshot = ClaudeUsageClient().get_usage()
    except (ClaudeUsageError, OSError) as exception:
        print("Claude usage check failed: " + str(exception), file=sys.stderr)
        return 1
    print("Claude subscription usage:")
    for window in snapshot.windows:
        reset = (
            window.reset_at_local.strftime("%Y-%m-%d %H:%M:%S %Z")
            if window.reset_at_local
            else "unknown"
        )
        print(
            "  {}: {}% remaining ({}% used); resets {}".format(
                window.label,
                window.remaining_percent,
                window.used_percent,
                reset,
            )
        )
    return 0


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=APP_NAME + " for Ubuntu")
    parser.add_argument(
        "--check",
        action="store_true",
        help=(
            "query the signed-in Claude.ai subscription once without "
            "starting the tray"
        ),
    )
    parser.add_argument(
        "--check-dependencies",
        action="store_true",
        help=argparse.SUPPRESS,
    )
    arguments = parser.parse_args(argv)

    if arguments.check:
        return print_live_usage()
    if arguments.check_dependencies:
        try:
            check_dependencies()
        except ClaudeUsageError as exception:
            print(str(exception), file=sys.stderr)
            return 1
        return 0

    instance_lock = SingleInstanceLock()
    if not instance_lock.acquire():
        return 0

    application: Optional[TrayApplication] = None
    try:
        executable_path = Path(sys.argv[0]).expanduser().resolve()
        application = TrayApplication(executable_path)

        def handle_signal(_number, _frame) -> None:
            assert application is not None
            application.GLib.idle_add(application.exit)

        signal.signal(signal.SIGTERM, handle_signal)
        signal.signal(signal.SIGINT, handle_signal)
        application.run()
        return 0
    except (ClaudeUsageError, OSError) as exception:
        print(str(exception), file=sys.stderr)
        return 1
    finally:
        if application is not None and not application.exiting:
            application.exit()
        instance_lock.release()


if __name__ == "__main__":
    sys.exit(main())

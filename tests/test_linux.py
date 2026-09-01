import datetime as dt
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import urllib.error


MODULE_PATH = Path(__file__).parents[1] / "linux" / "claude_usage_tray.py"
SPEC = importlib.util.spec_from_file_location("claude_usage_tray", MODULE_PATH)
tray = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(tray)


class UsageParserTests(unittest.TestCase):
    def test_parses_session_weekly_and_model_windows(self):
        response = {
            "five_hour": {
                "utilization": 27.4,
                "resets_at": "2026-09-01T18:30:00Z",
            },
            "seven_day": {
                "utilization": 42,
                "resets_at": "2026-09-05T04:00:00+00:00",
            },
            "seven_day_opus": None,
            "seven_day_sonnet": {
                "utilization": 12.6,
                "resets_at": None,
            },
        }

        snapshot = tray.parse_usage_response(response)

        self.assertEqual(27, snapshot.primary.used_percent)
        self.assertEqual(73, snapshot.primary.remaining_percent)
        self.assertIsInstance(snapshot.primary.reset_at_local, dt.datetime)
        self.assertEqual(42, snapshot.window("seven_day").used_percent)
        self.assertEqual(13, snapshot.window("seven_day_sonnet").used_percent)
        self.assertIsNone(snapshot.window("seven_day_opus"))

    def test_supports_documented_statusline_field_name_and_epoch_reset(self):
        snapshot = tray.parse_usage_response(
            {
                "five_hour": {
                    "used_percentage": 101,
                    "resets_at": 1_800_000_000,
                }
            }
        )

        self.assertEqual(100, snapshot.primary.used_percent)
        self.assertEqual(0, snapshot.primary.remaining_percent)
        self.assertIsInstance(snapshot.primary.reset_at_local, dt.datetime)

    def test_rejects_missing_windows(self):
        with self.assertRaisesRegex(tray.ClaudeUsageError, "no active"):
            tray.parse_usage_response({"extra_usage": {"is_enabled": False}})

    def test_rejects_non_numeric_or_non_finite_utilization(self):
        for bad_value in ("12", True, float("nan"), float("inf")):
            with self.subTest(value=bad_value):
                with self.assertRaisesRegex(
                    tray.ClaudeUsageError,
                    "omitted utilization",
                ):
                    tray.parse_usage_response(
                        {"five_hour": {"utilization": bad_value}}
                    )


class CredentialTests(unittest.TestCase):
    def test_environment_token_takes_precedence(self):
        token = tray.load_oauth_token(
            {"CLAUDE_CODE_OAUTH_TOKEN": "  environment-token  "},
            Path("/missing"),
        )
        self.assertEqual("environment-token", token)

    def test_reads_claude_managed_oauth_token(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            credential = home / ".claude" / ".credentials.json"
            credential.parent.mkdir()
            credential.write_text(
                json.dumps(
                    {"claudeAiOauth": {"accessToken": "saved-token"}}
                ),
                encoding="utf-8",
            )
            credential.chmod(0o600)

            token = tray.load_oauth_token({}, home)

            self.assertEqual("saved-token", token)

    def test_honors_claude_config_dir(self):
        with tempfile.TemporaryDirectory() as temporary:
            credential = Path(temporary) / ".credentials.json"
            credential.write_text(
                json.dumps(
                    {"claudeAiOauth": {"accessToken": "configured-token"}}
                ),
                encoding="utf-8",
            )
            credential.chmod(0o600)

            token = tray.load_oauth_token({"CLAUDE_CONFIG_DIR": temporary})

            self.assertEqual("configured-token", token)

    def test_rejects_overly_broad_credential_permissions(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            credential = home / ".claude" / ".credentials.json"
            credential.parent.mkdir()
            credential.write_text(
                json.dumps(
                    {"claudeAiOauth": {"accessToken": "saved-token"}}
                ),
                encoding="utf-8",
            )
            credential.chmod(0o644)

            with self.assertRaisesRegex(
                tray.ClaudeUsageError,
                "permissions are too broad",
            ):
                tray.load_oauth_token({}, home)

    def test_explains_missing_subscription_credentials(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            credential = home / ".claude" / ".credentials.json"
            credential.parent.mkdir()
            credential.write_text(
                json.dumps({"apiKey": "not-used"}),
                encoding="utf-8",
            )
            credential.chmod(0o600)

            with self.assertRaisesRegex(
                tray.ClaudeUsageError,
                "not signed in",
            ):
                tray.load_oauth_token({}, home)


class ConfigurationTests(unittest.TestCase):
    def test_refresh_interval_defaults_and_has_a_one_minute_floor(self):
        self.assertEqual(300, tray.refresh_interval_seconds({}))
        self.assertEqual(
            60,
            tray.refresh_interval_seconds(
                {tray.REFRESH_INTERVAL_VARIABLE: "5"}
            ),
        )
        self.assertEqual(
            900,
            tray.refresh_interval_seconds(
                {tray.REFRESH_INTERVAL_VARIABLE: "900"}
            ),
        )
        self.assertEqual(
            300,
            tray.refresh_interval_seconds(
                {tray.REFRESH_INTERVAL_VARIABLE: "nope"}
            ),
        )


class HttpClientTests(unittest.TestCase):
    def test_queries_read_only_usage_endpoint_with_oauth_header(self):
        response_payload = json.dumps(
            {"five_hour": {"utilization": 25, "resets_at": None}}
        ).encode("utf-8")
        response = mock.MagicMock()
        response.__enter__.return_value.read.return_value = response_payload

        with mock.patch.object(
            tray,
            "load_oauth_token",
            return_value="secret-token",
        ), mock.patch.object(
            tray.urllib.request,
            "urlopen",
            return_value=response,
        ) as urlopen:
            snapshot = tray.ClaudeUsageClient().get_usage()

        request = urlopen.call_args.args[0]
        self.assertEqual(tray.USAGE_ENDPOINT, request.full_url)
        self.assertEqual("GET", request.method)
        self.assertEqual(
            "Bearer secret-token",
            request.get_header("Authorization"),
        )
        self.assertEqual(
            tray.OAUTH_BETA,
            request.get_header("Anthropic-beta"),
        )
        self.assertEqual(75, snapshot.primary.remaining_percent)

    def test_401_does_not_echo_the_token(self):
        error = urllib.error.HTTPError(
            tray.USAGE_ENDPOINT,
            401,
            "Unauthorized",
            {},
            None,
        )
        with mock.patch.object(
            tray,
            "load_oauth_token",
            return_value="secret-token",
        ), mock.patch.object(
            tray.urllib.request,
            "urlopen",
            side_effect=error,
        ):
            with self.assertRaises(tray.ClaudeUsageError) as raised:
                tray.ClaudeUsageClient().get_usage()

        self.assertIn("rejected", str(raised.exception))
        self.assertNotIn("secret-token", str(raised.exception))

    def test_429_uses_retry_after_without_reading_response_body(self):
        response_body = io.BytesIO(b'{"sensitive":"body"}')
        error = urllib.error.HTTPError(
            tray.USAGE_ENDPOINT,
            429,
            "Too Many Requests",
            {"Retry-After": "731"},
            response_body,
        )
        with mock.patch.object(
            tray,
            "load_oauth_token",
            return_value="secret-token",
        ), mock.patch.object(
            tray.urllib.request,
            "urlopen",
            side_effect=error,
        ):
            with self.assertRaises(tray.ClaudeUsageError) as raised:
                tray.ClaudeUsageClient().get_usage()

        self.assertTrue(raised.exception.rate_limited)
        self.assertEqual(731, raised.exception.retry_after_seconds)
        self.assertNotIn("sensitive", str(raised.exception))
        self.assertEqual(0, response_body.tell())

    def test_rate_limit_backoff_uses_server_delay_when_longer(self):
        application = tray.TrayApplication.__new__(tray.TrayApplication)
        application.rate_limit_failures = 0
        application.consecutive_failures = 1
        error = tray.ClaudeUsageError(
            "rate limited",
            retry_after_seconds=731,
            rate_limited=True,
        )

        delay = application._retry_delay(error)

        self.assertEqual(731, delay)


class IconTests(unittest.TestCase):
    def test_writes_safe_offline_svg(self):
        with tempfile.TemporaryDirectory() as temporary:
            with mock.patch.dict(os.environ, {"XDG_CACHE_HOME": temporary}):
                root, name = tray.write_status_icon("<", "#cf222e", True)
                contents = (root / (name + ".svg")).read_text(
                    encoding="utf-8"
                )

        self.assertIn("&lt;", contents)
        self.assertIn('r="30.5"', contents)
        self.assertIn("claude-usage-v1-", name)


class DesktopIntegrationTests(unittest.TestCase):
    def test_startup_entry_quotes_executable_and_can_be_disabled(self):
        with tempfile.TemporaryDirectory() as temporary:
            executable = (
                Path(temporary)
                / "folder with spaces"
                / "claude-usage-tray"
            )
            with mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": temporary}):
                tray.set_startup_enabled(True, executable)
                contents = tray.autostart_path().read_text(encoding="utf-8")
                self.assertIn('Exec="{}"'.format(executable), contents)
                self.assertTrue(tray.startup_is_enabled())

                tray.set_startup_enabled(False, executable)
                self.assertFalse(tray.autostart_path().exists())


if __name__ == "__main__":
    unittest.main()

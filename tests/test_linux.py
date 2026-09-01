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
    def test_shared_mock_fixture_matches_endpoint_contract(self):
        fixture = MODULE_PATH.parents[1] / "tests" / "fixtures" / "usage_response.json"
        snapshot = tray.parse_usage_response(
            json.loads(fixture.read_text(encoding="utf-8"))
        )

        self.assertEqual(73, snapshot.primary.remaining_percent)
        self.assertEqual(42, snapshot.window("seven_day").used_percent)

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


class VersionTests(unittest.TestCase):
    def test_release_versions_stay_in_sync(self):
        expected = (MODULE_PATH.parents[1] / "VERSION").read_text(
            encoding="utf-8"
        ).strip()
        macos_source = (
            MODULE_PATH.parents[1] / "macos" / "ClaudeUsageTray.swift"
        ).read_text(encoding="utf-8")

        self.assertEqual(expected, tray.APP_VERSION)
        self.assertIn('appVersion = "{}"'.format(expected), macos_source)


class MacOSSourceContractTests(unittest.TestCase):
    def test_native_source_keeps_sensitive_boundary_explicit(self):
        source = (
            MODULE_PATH.parents[1] / "macos" / "ClaudeUsageTray.swift"
        ).read_text(encoding="utf-8")

        self.assertIn('keychainService = "Claude Code-credentials"', source)
        self.assertIn("kSecClassGenericPassword", source)
        self.assertIn("kSecMatchLimitAll", source)
        self.assertIn("isClaudeCredentialService", source)
        self.assertIn("rejectedKeychainServices", source)
        self.assertIn(tray.USAGE_ENDPOINT, source)
        self.assertIn('request.httpMethod = "GET"', source)
        self.assertIn('forHTTPHeaderField: "Authorization"', source)
        self.assertNotIn("refreshToken", source)

    def test_all_keychain_access_is_isolated_in_a_child_process(self):
        """Every Security-framework call must live in the child-mode function.

        The match-all Keychain sweep needed to find the hash-suffixed
        `Claude Code-credentials-<hash>` item corrupts the heap of whatever
        process runs it under `swiftc -O` on macOS 26. The damage surfaced far
        from its cause (SIGSEGV in a later SecItemCopyMatching, then a malloc
        trap inside CFNetwork), so the whole Keychain path is confined to a
        child process that exits immediately. The parent must never call
        Security. See CHANGELOG 0.2.1."""
        source = (
            MODULE_PATH.parents[1] / "macos" / "ClaudeUsageTray.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("--emit-credential", source)
        self.assertIn("func runCredentialEmit", source)

        child = source.split("func runCredentialEmit", 1)[1]
        child = child.split("\nprivate func ", 1)[0]

        # Every Security entry point appears only inside child mode.
        for symbol in (
            "SecItemCopyMatching",
            "kSecMatchLimitAll",
            "kSecReturnData",
            "SecCopyErrorMessageString",
        ):
            self.assertEqual(
                source.count(symbol),
                child.count(symbol),
                "{} must appear only inside runCredentialEmit".format(symbol),
            )
            self.assertGreater(child.count(symbol), 0, symbol)

        # The child exits without unwinding: its heap is already damaged.
        self.assertIn("Darwin.exit(0)", child)

        # The parent reaches it by re-launching itself.
        self.assertIn("Process()", source)
        self.assertIn("process.executableURL = currentExecutableURL", source)

    def test_child_credential_wire_format_carries_no_refresh_token(self):
        """Only the service name and access token cross the pipe, and the
        parent must not log either."""
        source = (
            MODULE_PATH.parents[1] / "macos" / "ClaudeUsageTray.swift"
        ).read_text(encoding="utf-8")

        self.assertIn('emit("OK', source)
        self.assertIn('emit("ERR', source)
        self.assertNotIn("refreshToken", source)
        # The token is never handed to the logger.
        self.assertNotIn("logger.info(\"\\(token", source)
        self.assertNotIn("logger.error(\"\\(token", source)

    def test_rejected_services_are_passed_to_the_child(self):
        """A 401 marks a service rejected; the next child run must skip it so
        the pre-0.2.1 fallback-to-next-candidate behavior survives."""
        source = (
            MODULE_PATH.parents[1] / "macos" / "ClaudeUsageTray.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("rejectedKeychainServices", source)
        self.assertIn('"--reject"', source)
        self.assertIn("rejecting rejected: Set<String>", source)

    def test_legacy_service_name_stays_a_fallback(self):
        """If the sweep fails or returns nothing, the unhashed item is still
        tried so the app degrades instead of dying."""
        source = (
            MODULE_PATH.parents[1] / "macos" / "ClaudeUsageTray.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("isClaudeCredentialService", source)
        self.assertIn("modifiedByService[keychainService] == nil", source)

    def test_menu_bar_shows_only_the_five_hour_window(self):
        """Requested scope: the menu tracks the current five-hour session
        window only. The weekly and all-windows menu entries were removed, so
        their outlets must be gone too."""
        source = (
            MODULE_PATH.parents[1] / "macos" / "ClaudeUsageTray.swift"
        ).read_text(encoding="utf-8")

        self.assertNotIn("weeklyItem", source)
        self.assertNotIn("weeklyResetItem", source)
        self.assertNotIn("allLimitsItem", source)
        self.assertIn("sessionResetItem", source)
        self.assertIn('window("five_hour")', source)

    def test_macos_installer_uses_user_launch_agent(self):
        installer = (
            MODULE_PATH.parents[1] / "macos" / "install.sh"
        ).read_text(encoding="utf-8")

        self.assertIn("$HOME/Library/LaunchAgents", installer)
        self.assertIn("launchctl bootstrap", installer)
        self.assertNotIn("sudo", installer)

    def test_root_scripts_dispatch_darwin_to_native_scripts(self):
        root = MODULE_PATH.parents[1]
        installer = (root / "install.sh").read_text(encoding="utf-8")
        uninstaller = (root / "uninstall.sh").read_text(encoding="utf-8")

        self.assertIn('exec "$project_root/macos/install.sh" "$@"', installer)
        self.assertIn(
            'exec "$project_root/macos/uninstall.sh" "$@"',
            uninstaller,
        )


if __name__ == "__main__":
    unittest.main()

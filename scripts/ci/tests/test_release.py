import copy
import json
import os
from pathlib import Path
import plistlib
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import release
import sign_release

SHA = "a" * 40
OTHER = "b" * 40
TAG = "v1.2.0"
INFO = {"CFBundleIdentifier": "local.quickshiftdisplay.app", "CFBundleExecutable": "QuickShiftDisplay",
        "CFBundleShortVersionString": "1.2.0", "CFBundleVersion": "6", "LSMinimumSystemVersion": "13.0"}


class FakeAPI:
    def __init__(self, tag_sha=None, existing_release=False, fail_upload=False, change_tag=False):
        self.tag_sha = tag_sha
        self.existing_release = existing_release
        self.fail_upload = fail_upload
        self.change_tag = change_tag
        self.calls = []

    def request(self, method, path, data=None, **kwargs):
        self.calls.append((method, path, data))
        if path.startswith("/releases/tags/"):
            return {"id": 1} if self.existing_release else None
        if path.startswith("/releases?"):
            return []
        if path.startswith("/git/ref/tags/"):
            return {"object": {"type": "commit", "sha": self.tag_sha}} if self.tag_sha else None
        if method == "POST" and path == "/releases":
            return {"id": 123, "upload_url": "https://uploads.github.test/release{?name,label}",
                    "html_url": "https://github.test/releases/123"}
        if path.startswith("https://uploads.github.test/"):
            if self.fail_upload:
                raise release.APIError(503, "Upload unavailable")
            if self.change_tag:
                self.tag_sha = OTHER
            return {"state": "uploaded"}
        if method == "POST" and path == "/git/refs":
            self.tag_sha = data["sha"]
            return {}
        if method == "PATCH":
            return {"id": 123, "html_url": "https://github.test/releases/123"}
        raise AssertionError((method, path))


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="quickshift-ci-tests-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.metadata = {"schema": 1, "tag": TAG, "source_sha": SHA, "app_version": "1.2.0",
                         "bundle_version": "6", "minimum_macos": "13.0", "architectures": release.ARCHITECTURES,
                         "archive": release.archive_name(TAG), "signing": "ad-hoc", "notarized": False}

    def bundle(self):
        target = self.root / "release"
        target.mkdir()
        with zipfile.ZipFile(target / self.metadata["archive"], "w") as archive:
            archive.writestr("QuickShift.app/Contents/Info.plist", plistlib.dumps(INFO))
            archive.writestr("QuickShift.app/Contents/MacOS/QuickShiftDisplay", b"test fixture, never executed")
        release.write_release_files(target, self.metadata)
        return target

    def test_tag_must_match_app_version_and_cannot_be_shell_or_output_text(self):
        self.assertEqual(release.validate_tag("v1.2.0-rc.1", "1.2.0"), "v1.2.0-rc.1")
        for tag in ["v2.0.0", "../v1.2.0", "v1.2.0\nkey=value", "v1.2.0;echo bad", "--latest"]:
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                release.validate_tag(tag, "1.2.0")

    def test_plan_records_actual_checked_out_sha_and_source_version(self):
        (self.root / "Resources").mkdir()
        (self.root / "Resources/Info.plist").write_bytes(plistlib.dumps(INFO))
        with patch.object(release, "run", return_value=SHA):
            plan = release.make_plan(self.root, TAG)
        self.assertEqual(plan["source_sha"], SHA)
        self.assertEqual(plan["app_version"], "1.2.0")
        self.assertEqual(plan["archive"], "QuickShift-v1.2.0-macOS-universal.zip")

    def test_valid_package_round_trip(self):
        target = self.bundle()
        self.assertEqual(release.verify_release_files(target, SHA, TAG, "ad-hoc"), self.metadata)

    @unittest.skipUnless(sys.platform == "darwin", "Requires the macOS compiler and signing tools")
    def test_real_universal_app_is_accepted_and_thin_app_is_rejected(self):
        app = self.root / "QuickShift.app"
        executable = app / "Contents/MacOS/QuickShiftDisplay"
        executable.parent.mkdir(parents=True)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({**INFO, "CFBundlePackageType": "APPL"}))
        source = self.root / "fixture.c"
        source.write_text("int main(void) { return 0; }\n")
        # Compile and sign a disposable fixture; never launch an app or use a certificate.
        release.run(["/usr/bin/xcrun", "clang", "-arch", "arm64", "-arch", "x86_64",
                     "-mmacosx-version-min=13.0", source, "-o", executable])
        release.run(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", app])
        release.validate_macos_app(app, self.metadata)
        thin = self.root / "thin-executable"
        release.run(["/usr/bin/lipo", executable, "-thin", "arm64", "-output", thin])
        thin.replace(executable)
        with self.assertRaisesRegex(RuntimeError, "lipo failed"):
            release.validate_macos_app(app, self.metadata)

    def test_package_tampering_is_rejected(self):
        target = self.bundle()
        (target / release.NOTES).write_text("changed")
        with self.assertRaises(ValueError):
            release.verify_release_files(target, SHA, TAG, "ad-hoc")

    def test_wrong_commit_or_channel_is_rejected(self):
        target = self.bundle()
        for sha, channel in [(OTHER, "ad-hoc"), (SHA, "developer-id")]:
            with self.subTest(sha=sha, channel=channel), self.assertRaises(ValueError):
                release.verify_release_files(target, sha, TAG, channel)

    def test_extra_files_are_not_publishable(self):
        target = self.bundle()
        (target / "unexpected.txt").write_text("not a release asset")
        with self.assertRaises(ValueError):
            release.verify_release_files(target, SHA, TAG, "ad-hoc")

    def test_archived_version_must_match_even_with_fresh_checksums(self):
        target = self.bundle()
        changed = copy.deepcopy(INFO)
        changed["CFBundleShortVersionString"] = "9.9.9"
        with zipfile.ZipFile(target / self.metadata["archive"], "w") as archive:
            archive.writestr("QuickShift.app/Contents/Info.plist", plistlib.dumps(changed))
        release.write_release_files(target, self.metadata)
        with self.assertRaises(ValueError):
            release.verify_release_files(target, SHA, TAG, "ad-hoc")

    def test_app_zip_rejects_traversal_and_symlinks(self):
        for unsafe in ["../outside", "/QuickShift.app/outside", "QuickShift.app/../../outside"]:
            path = self.root / "bad.zip"
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr(unsafe, b"no")
            with self.subTest(path=unsafe), self.assertRaises(ValueError):
                release.check_zip(path)
        with zipfile.ZipFile(path, "w") as archive:
            item = zipfile.ZipInfo("QuickShift.app/link")
            item.external_attr = (stat.S_IFLNK | 0o777) << 16
            archive.writestr(item, "/outside")
        with self.assertRaises(ValueError):
            release.check_zip(path)

    def test_existing_release_and_conflicting_tag_are_rejected(self):
        for api in [FakeAPI(existing_release=True), FakeAPI(tag_sha=OTHER)]:
            with self.assertRaises(ValueError):
                release.check_destination(api, TAG, SHA)
            self.assertFalse(any(call[0] == "POST" for call in api.calls))

    def test_annotated_tags_are_peeled(self):
        class AnnotatedAPI:
            def request(self, method, path, **kwargs):
                if path.startswith("/git/ref/"):
                    return {"object": {"type": "tag", "sha": OTHER}}
                return {"object": {"type": "commit", "sha": SHA}}
        self.assertEqual(release.tag_commit(AnnotatedAPI(), TAG), SHA)

    def test_existing_draft_is_detected_after_paginating_releases(self):
        class DraftAPI(FakeAPI):
            def request(self, method, path, data=None, **kwargs):
                if path == "/releases?per_page=100&page=1":
                    return [{"tag_name": f"v0.0.{index}", "draft": False} for index in range(100)]
                if path == "/releases?per_page=100&page=2":
                    return [{"tag_name": TAG, "draft": True}]
                return super().request(method, path, data, **kwargs)
        with self.assertRaisesRegex(ValueError, "draft already exists"):
            release.check_destination(DraftAPI(), TAG, SHA)

    def test_publish_uploads_all_assets_before_publishing_exact_commit(self):
        target = self.bundle()
        api = FakeAPI()
        release.publish(api, target, self.metadata, draft=False, prerelease=True)
        create = next(data for method, path, data in api.calls if method == "POST" and path == "/releases")
        self.assertTrue(create["draft"])
        self.assertTrue(create["prerelease"])
        self.assertEqual(create["target_commitish"], SHA)
        self.assertEqual(api.tag_sha, SHA)
        self.assertEqual(sum(path.startswith("https://uploads") for _, path, _ in api.calls), 4)
        self.assertEqual(api.calls[-1][0], "PATCH")
        self.assertFalse(api.calls[-1][2]["draft"])

    def test_draft_mode_never_publishes(self):
        api = FakeAPI()
        release.publish(api, self.bundle(), self.metadata, draft=True, prerelease=False)
        self.assertFalse(any(method == "PATCH" for method, _, _ in api.calls))

    def test_upload_failure_or_moved_tag_leaves_draft(self):
        target = self.bundle()
        for api in [FakeAPI(fail_upload=True), FakeAPI(change_tag=True)]:
            with self.assertRaises((ValueError, release.APIError)):
                release.publish(api, target, self.metadata, draft=False, prerelease=False)
            self.assertFalse(any(method == "PATCH" for method, _, _ in api.calls))

    def test_missing_signing_secrets_never_creates_a_keychain(self):
        with patch.dict(os.environ, {}, clear=True), self.assertRaises(ValueError):
            sign_release.sign_release(self.root, self.root / "out", self.root / "keys", SHA, TAG)
        self.assertFalse((self.root / "keys").exists())

    def fake_signing_commands(self, calls, status):
        def command(args, sensitive=False):
            args = [str(arg) for arg in args]
            calls.append(args)
            if args[0] == "/usr/bin/security":
                if args[1] == "list-keychains" and "-s" not in args:
                    return '"/fixture/original.keychain-db"'
                if args[1] == "create-keychain":
                    Path(args[-1]).touch()
                if args[1] == "find-identity":
                    return '1) ' + OTHER.upper() + ' "Developer ID Application: Fixture (TEST)"'
            if args[:3] == ["xcrun", "notarytool", "submit"]:
                return json.dumps({"status": status, "id": "fixture-submission"})
            return ""
        return command

    def fake_zip(self, app, destination):
        with zipfile.ZipFile(destination, "w") as archive:
            archive.writestr("QuickShift.app/Contents/Info.plist", plistlib.dumps(INFO))

    def signing_environment(self):
        return {"MACOS_CERTIFICATE_P12_BASE64": "dGVzdA==", "MACOS_CERTIFICATE_PASSWORD": "fixture-password",
                "APPLE_NOTARY_KEY_ID": "fixture-key", "APPLE_NOTARY_ISSUER_ID": "fixture-issuer",
                "APPLE_NOTARY_PRIVATE_KEY": "fixture-private-key"}

    def test_signing_requires_accepted_notarization_before_final_packaging(self):
        source, output, work, calls = self.bundle(), self.root / "signed", self.root / "keys", []
        with patch.dict(os.environ, self.signing_environment(), clear=True), \
                patch.object(sign_release, "run", side_effect=self.fake_signing_commands(calls, "Accepted")), \
                patch.object(sign_release, "validate_macos_app"), \
                patch.object(sign_release, "zip_app", side_effect=self.fake_zip):
            sign_release.sign_release(source, output, work, SHA, TAG)
        result = release.verify_release_files(output, SHA, TAG, "developer-id")
        self.assertTrue(result["notarized"])
        self.assertEqual(result["notarization_id"], "fixture-submission")
        self.assertTrue(any(args[:3] == ["xcrun", "stapler", "validate"] for args in calls))
        self.assertTrue(any(args[1] == "delete-keychain" for args in calls))
        self.assertIn(["/usr/bin/security", "list-keychains", "-d", "user", "-s", "/fixture/original.keychain-db"], calls)
        self.assertFalse(work.exists())

    def test_notarization_rejection_removes_credentials_and_creates_no_release_files(self):
        source, output, work, calls = self.bundle(), self.root / "signed", self.root / "keys", []
        with patch.dict(os.environ, self.signing_environment(), clear=True), \
                patch.object(sign_release, "run", side_effect=self.fake_signing_commands(calls, "Invalid")), \
                patch.object(sign_release, "validate_macos_app"), \
                patch.object(sign_release, "zip_app", side_effect=self.fake_zip), \
                self.assertRaisesRegex(ValueError, "not accepted"):
            sign_release.sign_release(source, output, work, SHA, TAG)
        self.assertFalse(output.exists())
        self.assertFalse(work.exists())
        self.assertTrue(any(args[1] == "delete-keychain" for args in calls))
        self.assertFalse(any(args[:2] == ["xcrun", "stapler"] for args in calls))


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Sign and notarize a CI build without executing the selected source revision."""
import argparse
import base64
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import shutil
import signal
import sys

from release import run, validate_macos_app, verify_release_files, write_release_files, zip_app

MARKER = "QuickShift signing workspace\n"
SECRET_NAMES = ["MACOS_CERTIFICATE_P12_BASE64", "MACOS_CERTIFICATE_PASSWORD",
                "APPLE_NOTARY_KEY_ID", "APPLE_NOTARY_ISSUER_ID", "APPLE_NOTARY_PRIVATE_KEY"]


def private_file(path, data):
    with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "wb") as stream:
        stream.write(data)


def cleanup(work):
    if not work.exists():
        return
    if work.is_symlink() or (work / ".owner").read_text() != MARKER:
        raise ValueError("Refusing to clean an unrecognized signing workspace")
    original = work / "original-keychains.json"
    if original.exists():
        run(["/usr/bin/security", "list-keychains", "-d", "user", "-s", *json.loads(original.read_text())], sensitive=True)
    keychain = work / "signing.keychain-db"
    if keychain.exists():
        run(["/usr/bin/security", "delete-keychain", keychain], sensitive=True)
    shutil.rmtree(work)


def sign_release(source, output, work, sha, tag):
    missing = [name for name in SECRET_NAMES if not os.environ.get(name)]
    if missing:
        raise ValueError("Developer ID mode requires repository secrets: " + ", ".join(missing))
    metadata = verify_release_files(source, sha, tag, "ad-hoc")
    work.mkdir(mode=0o700, parents=True, exist_ok=False)
    private_file(work / ".owner", MARKER.encode())
    try:
        # Archive paths and checksums were validated before extraction or importing keys.
        run(["/usr/bin/ditto", "-x", "-k", source / metadata["archive"], work / "unpacked"])
        app = work / "unpacked/QuickShift.app"
        validate_macos_app(app, metadata)
        encoded = "".join(os.environ["MACOS_CERTIFICATE_P12_BASE64"].split())
        private_file(work / "certificate.p12", base64.b64decode(encoded, validate=True))
        private_file(work / "AuthKey.p8", os.environ["APPLE_NOTARY_PRIVATE_KEY"].encode())
        original = shlex.split(run(["/usr/bin/security", "list-keychains", "-d", "user"]))
        private_file(work / "original-keychains.json", json.dumps(original).encode())
        keychain = work / "signing.keychain-db"
        password = secrets.token_urlsafe(32)
        run(["/usr/bin/security", "create-keychain", "-p", password, keychain], sensitive=True)
        run(["/usr/bin/security", "set-keychain-settings", "-lut", "21600", keychain], sensitive=True)
        run(["/usr/bin/security", "unlock-keychain", "-p", password, keychain], sensitive=True)
        run(["/usr/bin/security", "import", work / "certificate.p12", "-k", keychain,
             "-P", os.environ["MACOS_CERTIFICATE_PASSWORD"], "-T", "/usr/bin/codesign"], sensitive=True)
        run(["/usr/bin/security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:",
             "-s", "-k", password, keychain], sensitive=True)
        run(["/usr/bin/security", "list-keychains", "-d", "user", "-s", keychain, *original], sensitive=True)
        identities = re.findall(r'[0-9]+\)\s+([0-9A-Fa-f]{40}) "(Developer ID Application:[^"]+)"',
                                run(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning", keychain]))
        if len(identities) != 1:
            raise ValueError("Export exactly one valid Developer ID Application identity in the P12")
        run(["/usr/bin/codesign", "--force", "--sign", identities[0][0], "--keychain", keychain,
             "--options", "runtime", "--timestamp", app])
        validate_macos_app(app, metadata)
        submitted = work / "notarization.zip"
        zip_app(app, submitted)
        result = json.loads(run(["xcrun", "notarytool", "submit", submitted,
                                "--key", work / "AuthKey.p8", "--key-id", os.environ["APPLE_NOTARY_KEY_ID"],
                                "--issuer", os.environ["APPLE_NOTARY_ISSUER_ID"], "--wait", "--timeout", "20m",
                                "--output-format", "json"]))
        if result.get("status") != "Accepted":
            raise ValueError(f"Apple notarization was not accepted: {result.get('status')}; submission {result.get('id')}")
        run(["xcrun", "stapler", "staple", app])
        run(["xcrun", "stapler", "validate", app])
        run(["/usr/sbin/spctl", "--assess", "--type", "execute", "--verbose=2", app])
        validate_macos_app(app, metadata)
        metadata.update(signing="developer-id", notarized=True, notarization_id=result["id"])
        output.mkdir(parents=True, exist_ok=True)
        zip_app(app, output / metadata["archive"])
        write_release_files(output, metadata)
        verify_release_files(output, sha, tag, "developer-id")
    finally:
        cleanup(work)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cleanup", action="store_true")
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--input", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--sha")
    parser.add_argument("--tag")
    args = parser.parse_args()
    if args.cleanup:
        cleanup(args.work)
    else:
        if not all([args.input, args.output, args.sha, args.tag]):
            parser.error("--input, --output, --sha, and --tag are required")
        sign_release(args.input, args.output, args.work, args.sha, args.tag)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    try:
        main()
    except (ValueError, RuntimeError, OSError, KeyError) as error:
        print(f"Signing failed: {error}", file=sys.stderr)
        sys.exit(1)

#!/usr/bin/env python3
"""Plan, package, and publish a manually selected QuickShift revision."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import stat
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import zipfile

ARCHITECTURES = ["arm64", "x86_64"]
METADATA = "build-info.json"
NOTES = "release-notes.md"
SUMS = "SHA256SUMS.txt"


def run(args, sensitive=False):
    result = subprocess.run([str(a) for a in args], text=True, capture_output=True)
    if result.returncode:
        detail = "" if sensitive else ": " + result.stderr.strip()[-3000:]
        raise RuntimeError(f"{Path(args[0]).name} failed ({result.returncode}){detail}")
    return result.stdout.strip()


def validate_sha(sha):
    if not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", sha):
        raise ValueError("Expected a full commit SHA")
    return sha


def validate_tag(tag, version):
    match = re.fullmatch(r"v(\d+(?:\.\d+){1,2})(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?", tag)
    if not match or match[1] != version or len(tag) > 120:
        raise ValueError(f"Release tag must be v{version} or v{version}-<suffix>")
    return tag


def archive_name(tag):
    return f"QuickShift-{tag}-macOS-universal.zip"


def read_app_info(path):
    return app_info(plistlib.loads(path.read_bytes()))


def app_info(info):
    if info.get("CFBundleIdentifier") != "local.quickshiftdisplay.app" or info.get("CFBundleExecutable") != "QuickShiftDisplay":
        raise ValueError("The source or bundle is not QuickShift")
    version = info.get("CFBundleShortVersionString", "")
    if not isinstance(version, str) or not re.fullmatch(r"\d+(?:\.\d+){1,2}", version):
        raise ValueError("Invalid CFBundleShortVersionString")
    return {"app_version": version, "bundle_version": str(info["CFBundleVersion"]),
            "minimum_macos": str(info["LSMinimumSystemVersion"])}


def bundle_info(app):
    return read_app_info(app / "Contents/Info.plist")


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


class APIError(RuntimeError):
    def __init__(self, status, message):
        self.status = status
        super().__init__(f"GitHub API returned {status}: {message}")


class GitHubAPI:
    def __init__(self):
        token = os.environ.get("GH_TOKEN", "")
        repository = os.environ.get("GITHUB_REPOSITORY", "")
        if not token or not re.fullmatch(r"[\w.-]+/[\w.-]+", repository):
            raise ValueError("GH_TOKEN and GITHUB_REPOSITORY are required")
        self.base = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/") + "/repos/" + repository
        self.headers = {"Authorization": "Bearer " + token, "Accept": "application/vnd.github+json",
                        "X-GitHub-Api-Version": "2026-03-10", "User-Agent": "QuickShift-release"}

    def request(self, method, path, data=None, missing_ok=False, content_type="application/json"):
        url = path if path.startswith("https://") else self.base + path
        payload = data if isinstance(data, bytes) else json.dumps(data).encode() if data is not None else None
        request = urllib.request.Request(url, data=payload, method=method,
                                         headers={**self.headers, "Content-Type": content_type})
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            if missing_ok and error.code == 404:
                return None
            try:
                message = json.load(error).get("message", error.reason)
            except (ValueError, AttributeError):
                message = error.reason
            raise APIError(error.code, message) from None


def tag_commit(api, tag):
    ref = api.request("GET", "/git/ref/tags/" + urllib.parse.quote(tag, safe=""), missing_ok=True)
    if ref is None:
        return None
    obj = ref["object"]
    for _ in range(10):
        if obj["type"] == "commit":
            return validate_sha(obj["sha"])
        if obj["type"] != "tag":
            break
        obj = api.request("GET", "/git/tags/" + validate_sha(obj["sha"]))["object"]
    raise ValueError("Release tag does not resolve to a commit")


def check_destination(api, tag, sha):
    if api.request("GET", "/releases/tags/" + urllib.parse.quote(tag, safe=""), missing_ok=True) is not None:
        raise ValueError("A release already exists for this tag; existing releases are never overwritten")
    # The tag endpoint only guarantees published releases; include visible drafts.
    page = 1
    while True:
        releases = api.request("GET", f"/releases?per_page=100&page={page}")
        if any(item["tag_name"] == tag for item in releases):
            raise ValueError("A release or draft already exists for this tag; remove a failed draft before retrying")
        if len(releases) < 100:
            break
        page += 1
    existing = tag_commit(api, tag)
    if existing is not None and existing != sha:
        raise ValueError("The existing tag points to a different commit")


def make_plan(source, tag):
    info = read_app_info(source / "Resources/Info.plist")
    validate_tag(tag, info["app_version"])
    sha = validate_sha(run(["git", "-C", source, "rev-parse", "HEAD"]))
    repository = os.environ.get("GITHUB_REPOSITORY", "")
    server = os.environ.get("GITHUB_SERVER_URL", "https://github.com")
    return {"schema": 1, "tag": tag, "source_sha": sha, **info,
            "architectures": ARCHITECTURES, "archive": archive_name(tag), "signing": "ad-hoc", "notarized": False,
            "workflow_sha": os.environ.get("WORKFLOW_SHA", ""),
            "run_url": f"{server}/{repository}/actions/runs/{os.environ.get('GITHUB_RUN_ID', '')}"}


def check_zip(path):
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        if len(entries) > 10000 or sum(item.file_size for item in entries) > 512 * 1024 * 1024:
            raise ValueError("App archive exceeds expected limits")
        for item in entries:
            parts = PurePosixPath(item.filename).parts
            if not parts or parts[0] not in ("QuickShift.app", "__MACOSX") or ".." in parts or "\\" in item.filename:
                raise ValueError("Unexpected app archive path")
            if stat.S_ISLNK(item.external_attr >> 16):
                raise ValueError("This app package must not contain symbolic links")
        if "QuickShift.app/Contents/Info.plist" not in archive.namelist():
            raise ValueError("QuickShift.app is missing from the archive")
        if archive.testzip() is not None:
            raise ValueError("Damaged app archive")
        return app_info(plistlib.loads(archive.read("QuickShift.app/Contents/Info.plist")))


def validate_macos_app(app, metadata):
    if bundle_info(app) != {key: metadata[key] for key in ("app_version", "bundle_version", "minimum_macos")}:
        raise ValueError("Built bundle version differs from selected source")
    run(["/usr/bin/lipo", "-verify_arch", *ARCHITECTURES, app / "Contents/MacOS/QuickShiftDisplay"])
    run(["/usr/bin/codesign", "--verify", "--strict", "--all-architectures", app])


def zip_app(app, destination):
    run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, destination])
    check_zip(destination)


def write_release_files(output, metadata):
    output.mkdir(parents=True, exist_ok=True)
    signing = "Developer ID signed and notarized" if metadata["notarized"] else "Ad hoc signed; not notarized"
    notes = (f"# QuickShift {metadata['tag']}\n\n"
             f"- macOS {metadata['minimum_macos']} or later; Apple Silicon and Intel universal app.\n"
             f"- Source commit: `{metadata['source_sha']}`.\n- App version: `{metadata['app_version']}`.\n"
             f"- Distribution: {signing}.\n\n"
             "Extract the ZIP, move QuickShift.app to Applications, open it, grant Accessibility permission, "
             "and enable global shortcuts. Defaults: Control + Command + Shift + left/right mouse click.\n\n"
             "Ad hoc builds can require renewed Accessibility permission after an update. "
             "SHA256SUMS.txt verifies the archive and accompanying metadata.\n")
    (output / NOTES).write_text(notes, encoding="utf-8")
    (output / METADATA).write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    names = [metadata["archive"], METADATA, NOTES]
    (output / SUMS).write_text("".join(f"{digest(output / name)}  {name}\n" for name in names), encoding="utf-8")


def verify_release_files(directory, sha, tag, signing):
    for name in (METADATA, NOTES, SUMS):
        if not (directory / name).is_file() or (directory / name).is_symlink():
            raise ValueError("Release metadata must be regular files")
    metadata = json.loads((directory / METADATA).read_text())
    validate_sha(sha)
    validate_tag(tag, metadata["app_version"])
    if (metadata.get("schema") != 1 or metadata.get("source_sha") != sha or metadata.get("tag") != tag
            or metadata.get("signing") != signing or metadata.get("architectures") != ARCHITECTURES
            or metadata.get("archive") != archive_name(tag)
            or metadata.get("notarized") != (signing == "developer-id")):
        raise ValueError("Release metadata does not match the requested build")
    expected = {archive_name(tag), METADATA, NOTES}
    checksums = {}
    for line in (directory / SUMS).read_text().splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
        if not match or match[2] not in expected or match[2] in checksums:
            raise ValueError("Invalid checksum manifest")
        checksums[match[2]] = match[1]
    if set(checksums) != expected or {p.name for p in directory.iterdir()} != expected | {SUMS}:
        raise ValueError("Release files are missing or unexpected files are present")
    for name, checksum in checksums.items():
        path = directory / name
        if not path.is_file() or path.is_symlink() or digest(path) != checksum:
            raise ValueError(f"Checksum mismatch: {name}")
    if check_zip(directory / metadata["archive"]) != {
        key: metadata[key] for key in ("app_version", "bundle_version", "minimum_macos")
    }:
        raise ValueError("Archived app version differs from release metadata")
    return metadata


def publish(api, directory, metadata, draft, prerelease):
    tag, sha = metadata["tag"], metadata["source_sha"]
    check_destination(api, tag, sha)
    # Assemble every asset in a draft, then publish only after all uploads succeed.
    release = api.request("POST", "/releases", {"tag_name": tag, "target_commitish": sha,
                          "name": "QuickShift " + tag, "body": (directory / NOTES).read_text(),
                          "draft": True, "prerelease": prerelease})
    upload = release["upload_url"].split("{", 1)[0]
    for name in [metadata["archive"], SUMS, METADATA, NOTES]:
        kind = "application/zip" if name.endswith(".zip") else "application/json" if name.endswith(".json") else "text/plain"
        api.request("POST", upload + "?name=" + urllib.parse.quote(name, safe=""),
                    (directory / name).read_bytes(), content_type=kind)
    existing = tag_commit(api, tag)
    if existing is None:
        try:
            api.request("POST", "/git/refs", {"ref": "refs/tags/" + tag, "sha": sha})
        except APIError as error:
            if error.status != 422:
                raise
        existing = tag_commit(api, tag)
    if existing != sha:
        raise ValueError("Tag changed during the build; the release remains a draft")
    if not draft:
        release = api.request("PATCH", f"/releases/{release['id']}", {"draft": False, "make_latest": "legacy"})
    return release["html_url"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    plan = sub.add_parser("plan")
    plan.add_argument("--source", type=Path, required=True)
    plan.add_argument("--tag", required=True)
    plan.add_argument("--output", type=Path, required=True)
    plan.add_argument("--check-github", action="store_true")
    package = sub.add_parser("package")
    package.add_argument("--plan", type=Path, required=True)
    package.add_argument("--app", type=Path, required=True)
    package.add_argument("--output", type=Path, required=True)
    upload = sub.add_parser("publish")
    upload.add_argument("--input", type=Path, required=True)
    upload.add_argument("--sha", required=True)
    upload.add_argument("--tag", required=True)
    upload.add_argument("--signing", choices=["ad-hoc", "developer-id"], required=True)
    args = parser.parse_args()
    if args.command == "plan":
        metadata = make_plan(args.source, args.tag)
        if args.check_github:
            check_destination(GitHubAPI(), args.tag, metadata["source_sha"])
        args.output.write_text(json.dumps(metadata, indent=2) + "\n")
        if os.environ.get("GITHUB_OUTPUT"):
            with open(os.environ["GITHUB_OUTPUT"], "a") as output:
                output.write("source_sha=" + metadata["source_sha"] + "\n")
        print(f"Build {metadata['source_sha']} as {metadata['tag']}")
    elif args.command == "package":
        metadata = json.loads(args.plan.read_text())
        validate_macos_app(args.app, metadata)
        args.output.mkdir(parents=True, exist_ok=True)
        zip_app(args.app, args.output / metadata["archive"])
        write_release_files(args.output, metadata)
        verify_release_files(args.output, metadata["source_sha"], metadata["tag"], "ad-hoc")
    else:
        metadata = verify_release_files(args.input, args.sha, args.tag, args.signing)
        url = publish(GitHubAPI(), args.input, metadata, os.environ.get("RELEASE_DRAFT") == "true",
                      os.environ.get("RELEASE_PRERELEASE") == "true")
        print(url)
        if os.environ.get("GITHUB_STEP_SUMMARY"):
            with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
                summary.write(f"## QuickShift release\n\n{url}\n\nCommit: `{args.sha}`\n")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError, OSError, KeyError, zipfile.BadZipFile) as error:
        print(f"Release failed: {error}", file=sys.stderr)
        sys.exit(1)

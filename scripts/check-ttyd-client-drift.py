#!/usr/bin/env python3
"""Report ttyd client source, release, dependency, and advisory drift.

Exit 0 means no observed drift in the queried sources, 10 means observed drift
or a published-advisory set change, and 2 means at least one required source was
unevaluated. No outcome is a claim that the artifact is safe.
"""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import hashlib
import json
import os
import re
import shutil
import ssl
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_MANIFEST = ROOT / "ttyd" / "reproducibility.env"


def load_manifest(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        match = re.fullmatch(r"([A-Z0-9_]+)=(.*)", line)
        if not match:
            raise ValueError(f"line {number} is not KEY=value")
        value = match.group(2)
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
            value = value[1:-1]
        values[match.group(1)] = value
    return values


class Sources:
    def __init__(self, timeout: float):
        self.timeout = timeout
        self.unevaluated: list[str] = []
        self.headers = {
            "Accept": "application/vnd.github+json",
            "User-Agent": "coding-agent-sandbox-ttyd-drift-check/1",
            "X-GitHub-Api-Version": "2022-11-28",
        }
        self.token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
        if not self.token and shutil.which("gh"):
            result = subprocess.run(
                ["gh", "auth", "token"], capture_output=True, text=True, check=False
            )
            if result.returncode == 0:
                self.token = result.stdout.strip()
        cert = ROOT / "certs" / "Cloudflare_CA.crt"
        self.context = ssl.create_default_context()
        if cert.is_file():
            self.context.load_verify_locations(cafile=str(cert))

    def json(self, label: str, url: str, payload: Any | None = None) -> Any | None:
        data = None if payload is None else json.dumps(payload).encode("utf-8")
        headers = dict(self.headers)
        if self.token and urllib.parse.urlparse(url).hostname == "api.github.com":
            headers["Authorization"] = f"Bearer {self.token}"
        if data is not None:
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(url, data=data, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=self.timeout, context=self.context) as response:
                return json.load(response)
        except (OSError, ValueError, urllib.error.URLError) as error:
            reason = getattr(error, "reason", error)
            item = f"{label}: {reason}"
            self.unevaluated.append(item)
            print(f"UNEVALUATED {item}")
            return None


def content_from_api(sources: Sources, label: str, url: str) -> bytes | None:
    result = sources.json(label, url)
    if not isinstance(result, dict) or not isinstance(result.get("content"), str):
        if result is not None:
            item = f"{label}: response did not contain file content"
            sources.unevaluated.append(item)
            print(f"UNEVALUATED {item}")
        return None
    try:
        return base64.b64decode(result["content"], validate=False)
    except ValueError as error:
        item = f"{label}: invalid base64 content: {error}"
        sources.unevaluated.append(item)
        print(f"UNEVALUATED {item}")
        return None


def lock_packages(lock: bytes) -> dict[str, list[str]]:
    packages: dict[str, set[str]] = {}
    pattern = re.compile(r'^  resolution: "(.+?)@npm:([^"#]+)"$', re.MULTILINE)
    for name, version in pattern.findall(lock.decode("utf-8")):
        packages.setdefault(name, set()).add(version)
    return {name: sorted(versions) for name, versions in packages.items()}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--timeout", type=float, default=float(os.environ.get("TTYD_HTTP_TIMEOUT", "15")))
    args = parser.parse_args()

    try:
        manifest = load_manifest(args.manifest)
    except (OSError, ValueError) as error:
        print(f"UNEVALUATED manifest: {error}")
        return 2

    required = {
        "TTYD_SOURCE_REPOSITORY",
        "TTYD_SOURCE_COMMIT",
        "TTYD_SOURCE_TREE",
        "TTYD_SOURCE_COMMITTED_AT",
        "TTYD_SOURCE_DEFAULT_BRANCH",
        "TTYD_PACKAGE_JSON_SHA256",
        "TTYD_YARN_LOCK_SHA256",
        "TTYD_NPM_ADVISORY_BASELINE_COUNT",
        "TTYD_NPM_ADVISORY_BASELINE_SHA256",
    }
    missing = sorted(required - manifest.keys())
    if missing:
        print(f"UNEVALUATED manifest: missing {', '.join(missing)}")
        return 2
    if not manifest["TTYD_NPM_ADVISORY_BASELINE_COUNT"].isdigit() or not re.fullmatch(
        r"[0-9a-f]{64}", manifest["TTYD_NPM_ADVISORY_BASELINE_SHA256"]
    ):
        print("UNEVALUATED manifest: malformed npm advisory baseline")
        return 2

    repository = manifest["TTYD_SOURCE_REPOSITORY"]
    match = re.fullmatch(r"https://github\.com/([^/]+)/([^/.]+)(?:\.git)?", repository)
    if not match:
        print(f"UNEVALUATED manifest: unsupported GitHub repository {repository}")
        return 2
    owner, repo = match.groups()
    commit = manifest["TTYD_SOURCE_COMMIT"]
    branch = manifest["TTYD_SOURCE_DEFAULT_BRANCH"]
    committed_at = dt.datetime.fromisoformat(manifest["TTYD_SOURCE_COMMITTED_AT"].replace("Z", "+00:00"))
    github = os.environ.get("TTYD_GITHUB_API_BASE", "https://api.github.com").rstrip("/")
    npm = os.environ.get("TTYD_NPM_REGISTRY_BASE", "https://registry.npmjs.org").rstrip("/")
    sources = Sources(args.timeout)
    drift = False

    print("Sources:")
    print(f"  GitHub REST API: {github}/repos/{owner}/{repo}")
    print(f"  npm advisory bulk API: {npm}/-/npm/v1/security/advisories/bulk")

    commit_result = sources.json(
        "github.commit-identity", f"{github}/repos/{owner}/{repo}/git/commits/{commit}"
    )
    if isinstance(commit_result, dict):
        actual_commit = commit_result.get("sha")
        actual_tree = (commit_result.get("tree") or {}).get("sha")
        if actual_commit == commit and actual_tree == manifest["TTYD_SOURCE_TREE"]:
            print(f"UNCHANGED commit identity: {actual_commit}, tree {actual_tree}")
        else:
            print(
                "DRIFT commit identity: "
                f"commit={actual_commit!r} tree={actual_tree!r}; "
                f"expected commit={commit} tree={manifest['TTYD_SOURCE_TREE']}"
            )
            drift = True

    compare = sources.json(
        "github.commits-since", f"{github}/repos/{owner}/{repo}/compare/{commit}...{branch}?per_page=100"
    )
    if isinstance(compare, dict):
        ahead = compare.get("ahead_by")
        commits = compare.get("commits") if isinstance(compare.get("commits"), list) else []
        print(f"OBSERVED upstream commits since pin: {ahead}")
        for item in commits[-10:]:
            message = ((item.get("commit") or {}).get("message") or "").splitlines()[0]
            print(f"  {str(item.get('sha', ''))[:12]} {message}")
        drift = drift or bool(ahead)

    releases = sources.json("github.releases", f"{github}/repos/{owner}/{repo}/releases?per_page=100")
    if isinstance(releases, list):
        newer = []
        for release in releases:
            published = release.get("published_at")
            if published and dt.datetime.fromisoformat(published.replace("Z", "+00:00")) > committed_at:
                newer.append((release.get("tag_name"), published))
        print(f"OBSERVED releases published since pin: {len(newer)}")
        for tag, published in newer:
            print(f"  {tag} {published}")
        drift = drift or bool(newer)

    encoded_branch = urllib.parse.quote(branch, safe="")
    package_url = f"{github}/repos/{owner}/{repo}/contents/html/package.json?ref={encoded_branch}"
    lock_url = f"{github}/repos/{owner}/{repo}/contents/html/yarn.lock?ref={encoded_branch}"
    current_package = content_from_api(sources, "github.current-package-json", package_url)
    current_lock = content_from_api(sources, "github.current-yarn-lock", lock_url)
    for label, content, expected in (
        ("package.json", current_package, manifest["TTYD_PACKAGE_JSON_SHA256"]),
        ("yarn.lock", current_lock, manifest["TTYD_YARN_LOCK_SHA256"]),
    ):
        if content is not None:
            actual = hashlib.sha256(content).hexdigest()
            state = "UNCHANGED" if actual == expected else "DRIFT"
            print(f"{state} dependency input {label}: {actual}")
            drift = drift or actual != expected

    pinned_lock_url = f"{github}/repos/{owner}/{repo}/contents/html/yarn.lock?ref={commit}"
    pinned_lock = content_from_api(sources, "github.pinned-yarn-lock", pinned_lock_url)
    if pinned_lock is not None:
        packages = lock_packages(pinned_lock)
        if not packages:
            item = "npm.advisories: no npm resolutions parsed from pinned yarn.lock"
            sources.unevaluated.append(item)
            print(f"UNEVALUATED {item}")
        else:
            advisories = sources.json(
                "npm.advisories",
                f"{npm}/-/npm/v1/security/advisories/bulk",
                packages,
            )
            if isinstance(advisories, dict):
                keys = sorted(
                    {
                        "|".join(
                            (
                                name,
                                str(advisory.get("id", "")),
                                str(advisory.get("url", "")),
                                str(advisory.get("severity", "")),
                                str(advisory.get("vulnerable_versions", "")),
                            )
                        )
                        for name, items in advisories.items()
                        if isinstance(items, list)
                        for advisory in items
                        if isinstance(advisory, dict)
                    }
                )
                count = len(keys)
                fingerprint = hashlib.sha256("\n".join(keys).encode("utf-8")).hexdigest()
                baseline_count = int(manifest["TTYD_NPM_ADVISORY_BASELINE_COUNT"])
                baseline_fingerprint = manifest["TTYD_NPM_ADVISORY_BASELINE_SHA256"]
                advisory_changed = count != baseline_count or fingerprint != baseline_fingerprint
                advisory_state = "DRIFT" if advisory_changed else "UNCHANGED"
                print(
                    f"{advisory_state} npm published-advisory set for {len(packages)} locked packages: "
                    f"{count} unique records, sha256 {fingerprint}; zero or unchanged is not a claim of safety"
                )
                if advisory_changed:
                    for name, items in sorted(advisories.items()):
                        if not isinstance(items, list):
                            continue
                        for advisory in items:
                            print(
                                f"  {name}: {advisory.get('severity', 'unknown')} "
                                f"{advisory.get('title', 'untitled')} "
                                f"({advisory.get('url', 'no-url')})"
                            )
                drift = drift or advisory_changed

    if sources.unevaluated:
        print(f"RESULT UNEVALUATED: {len(sources.unevaluated)} required source(s) could not be classified")
        return 2
    if drift:
        print("RESULT DRIFT: review upstream/dependency changes; no file was updated")
        return 10
    print("RESULT NO-OBSERVED-DRIFT: no file was updated; this is not a claim of safety")
    return 0


if __name__ == "__main__":
    sys.exit(main())

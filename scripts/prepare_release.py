#!/usr/bin/env python3
"""Read-only guards for publishing one verified master commit.

The workflow calls this before building and immediately before publication.
All API operations are GET requests; this script never creates or moves refs.
"""

from __future__ import annotations

import json
import argparse
import os
from pathlib import Path
import re
import subprocess
import sys
from dataclasses import dataclass
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode
from urllib.request import Request, urlopen


class ReleaseError(RuntimeError):
    """A release precondition was not satisfied."""


VERSION = r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
SHA = re.compile(r"[0-9a-f]{40}")
RELEASE_PAGE_SIZE = 100
MAX_RELEASE_PAGES = 20


def resolve_tag(ref: str) -> str:
    for prefix in ("refs/tags/", "refs/heads/release/"):
        if ref.startswith(prefix):
            tag = ref[len(prefix) :]
            if re.fullmatch(rf"v{VERSION}", tag):
                return tag
            break
    raise ReleaseError(
        "Choose a stable vX.Y.Z tag or release/vX.Y.Z branch; "
        "ordinary branches such as master cannot publish a release."
    )


def parse_version(pubspec: str) -> tuple[str, int]:
    lines = re.findall(r"^version:\s*([^\r\n]+)$", pubspec, flags=re.MULTILINE)
    if len(lines) != 1:
        raise ReleaseError("pubspec.yaml must contain exactly one version field.")
    match = re.fullmatch(
        rf"(?P<quote>['\"]?)(?P<version>{VERSION})"
        r"\+(?P<build>[1-9][0-9]*)(?P=quote)\s*(?:#.*)?",
        lines[0].strip(),
    )
    if not match:
        raise ReleaseError("pubspec version must be X.Y.Z with a positive +build number.")
    return match["version"], int(match["build"])


class GitHubReader:
    def __init__(self, repository: str, token: str):
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
            raise ReleaseError("Invalid repository name.")
        if not token:
            raise ReleaseError("The workflow's existing GitHub token is required.")
        self.base = f"https://api.github.com/repos/{repository}"
        self.token = token

    def get(self, path: str, *, missing_ok: bool = False):
        request = Request(
            self.base + path,
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {self.token}",
                "X-GitHub-Api-Version": "2022-11-28",
                "User-Agent": "DanbooruViewer-release-validation",
            },
        )
        try:
            with urlopen(request, timeout=30) as response:
                return json.load(response)
        except HTTPError as error:
            if missing_ok and error.code == 404:
                return None
            raise ReleaseError(f"GitHub read failed for {path}: HTTP {error.code}.") from None
        except (URLError, TimeoutError, ValueError) as error:
            raise ReleaseError(f"GitHub read failed for {path}: {type(error).__name__}.") from None


def verify_tag_target(
    api: GitHubReader, tag: str, sha: str, *, required: bool = False
) -> bool:
    ref = api.get(f"/git/ref/tags/{quote(tag, safe='')}", missing_ok=True)
    if ref is None:
        if required:
            raise ReleaseError("The release tag must exist before publication.")
        return False
    obj = ref.get("object", {})
    for _ in range(10):
        object_sha = obj.get("sha", "")
        if not isinstance(object_sha, str) or not SHA.fullmatch(object_sha):
            raise ReleaseError("The existing release tag has an invalid object SHA.")
        if obj.get("type") == "commit":
            if object_sha != sha:
                raise ReleaseError("The release tag already points to a different commit.")
            return True
        if obj.get("type") != "tag":
            raise ReleaseError("The release tag does not resolve to a commit.")
        obj = api.get(f"/git/tags/{object_sha}").get("object", {})
    raise ReleaseError("The release tag has too many nested annotated tags.")


def verify_no_existing_release(api: GitHubReader, tag: str) -> None:
    # The tag-specific endpoint omits drafts. Listing returns every release
    # visible to this token; the final check uses the publishing job's writer
    # token so it can also detect drafts before gh release create is called.
    for page in range(1, MAX_RELEASE_PAGES + 1):
        releases = api.get(f"/releases?per_page={RELEASE_PAGE_SIZE}&page={page}")
        if (
            not isinstance(releases, list)
            or len(releases) > RELEASE_PAGE_SIZE
            or any(
                not isinstance(release, dict)
                or not isinstance(release.get("tag_name"), str)
                for release in releases
            )
        ):
            raise ReleaseError("GitHub returned an invalid release list; publication is blocked.")
        if any(release["tag_name"] == tag for release in releases):
            raise ReleaseError(
                "A release already exists for this tag; existing releases are not overwritten."
            )
        if len(releases) < RELEASE_PAGE_SIZE:
            return
    raise ReleaseError(
        "Release listing exceeded the pagination limit; cannot safely verify that the tag is unused."
    )


@dataclass(frozen=True)
class ReleaseMetadata:
    tag: str
    sha: str
    version: str
    build: int
    ci_url: str
    tag_exists: bool


def validate_release(
    api: GitHubReader,
    *,
    ref: str,
    sha: str,
    checked_out_sha: str,
    pubspec: str,
    base_branch: str = "master",
    require_tag: bool = False,
) -> ReleaseMetadata:
    tag = resolve_tag(ref)
    if not SHA.fullmatch(sha) or checked_out_sha != sha:
        raise ReleaseError("The checkout must match the exact triggering commit SHA.")
    version, build = parse_version(pubspec)
    if tag != f"v{version}":
        raise ReleaseError("The release tag must exactly match the pubspec version.")

    comparison = api.get(f"/compare/{sha}...{quote(base_branch, safe='')}")
    if (
        comparison.get("status") not in ("ahead", "identical")
        or comparison.get("merge_base_commit", {}).get("sha") != sha
    ):
        raise ReleaseError(f"The release commit has not been merged into {base_branch}.")

    # The newest CI push run for this exact master commit must have succeeded.
    # Never use an older success when a more recent run is pending or failed.
    query = urlencode(
        {"event": "push", "head_sha": sha, "branch": base_branch, "per_page": 100}
    )
    data = api.get(f"/actions/workflows/ci.yml/runs?{query}")
    runs = [
        run
        for run in data.get("workflow_runs", [])
        if run.get("head_sha") == sha
        and run.get("event") == "push"
        and run.get("head_branch") == base_branch
    ]
    if not runs:
        raise ReleaseError(f"No CI push run was found for this exact {base_branch} commit.")
    latest = max(runs, key=lambda run: (int(run["id"]), int(run.get("run_attempt", 1))))
    if latest.get("status") != "completed" or latest.get("conclusion") != "success":
        raise ReleaseError("The latest CI push run is not successful; wait for or repair CI first.")

    tag_exists = verify_tag_target(api, tag, sha, required=require_tag)
    verify_no_existing_release(api, tag)

    return ReleaseMetadata(tag, sha, version, build, latest.get("html_url", ""), tag_exists)


def main(argv: list[str] | None = None) -> int:
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--guide", action="store_true",
        help="Print the local release guide without Git/API operations or changes.",
    )
    args = parser.parse_args(argv)
    if args.guide:
        print((root / "RELEASE_GUIDE.md").read_text(encoding="utf-8"))
        return 0
    try:
        head = subprocess.check_output(
            ["git", "rev-parse", "HEAD^{commit}"], cwd=root, text=True
        ).strip()
        pubspec = subprocess.check_output(
            ["git", "show", "HEAD:pubspec.yaml"], cwd=root, text=True
        )
        metadata = validate_release(
            GitHubReader(os.environ.get("GITHUB_REPOSITORY", ""), os.environ.get("GH_TOKEN", "")),
            ref=os.environ.get("GITHUB_REF", ""),
            sha=os.environ.get("GITHUB_SHA", ""),
            checked_out_sha=head,
            pubspec=pubspec,
            require_tag=os.environ.get("RELEASE_REQUIRE_TAG") == "true",
        )
        output = os.environ.get("GITHUB_OUTPUT")
        if output:
            with Path(output).open("a", encoding="utf-8") as stream:
                stream.write(
                    f"tag={metadata.tag}\nsha={metadata.sha}\n"
                    f"tag_exists={str(metadata.tag_exists).lower()}\n"
                )
        print(f"Validated {metadata.tag} at {metadata.sha}; CI: {metadata.ci_url}")
        return 0
    except (ReleaseError, subprocess.CalledProcessError, OSError) as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

"""Release guards fail closed before signing or publishing unverified code."""

from copy import deepcopy
from pathlib import Path
import sys
import unittest
from urllib.error import HTTPError
from urllib.parse import parse_qs, urlsplit
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

import prepare_release  # noqa: E402
from prepare_release import (  # noqa: E402
    GitHubReader,
    MAX_RELEASE_PAGES,
    RELEASE_PAGE_SIZE,
    ReleaseError,
    parse_version,
    resolve_tag,
    validate_release,
)


COMMIT = "a" * 40
OTHER_COMMIT = "b" * 40
TAG_OBJECT = "c" * 40
TAG = "v1.0.67"


class FakeGitHub:
    def __init__(self):
        self.comparison = {
            "status": "identical",
            "merge_base_commit": {"sha": COMMIT},
        }
        self.runs = [
            {
                "id": 123,
                "run_attempt": 1,
                "head_sha": COMMIT,
                "head_branch": "master",
                "event": "push",
                "status": "completed",
                "conclusion": "success",
                "html_url": "https://github.com/example/viewer/actions/runs/123",
            }
        ]
        self.ref = None
        self.release_pages = {1: []}
        self.tag_objects = {}
        self.calls = []

    def get(self, path, *, missing_ok=False):
        self.calls.append(path)
        if path == f"/compare/{COMMIT}...master":
            return deepcopy(self.comparison)
        if path.startswith("/actions/workflows/ci.yml/runs?"):
            return {"workflow_runs": deepcopy(self.runs)}
        if path == f"/git/ref/tags/{TAG}":
            return deepcopy(self.ref)
        if path.startswith("/git/tags/"):
            return deepcopy(self.tag_objects[path.rsplit("/", 1)[-1]])
        if path.startswith("/releases?"):
            query = parse_qs(urlsplit(path).query)
            if query.get("per_page") != ["100"]:
                raise AssertionError(f"Unexpected release page size: {path}")
            return deepcopy(self.release_pages.get(int(query["page"][0]), []))
        raise AssertionError(f"Unexpected API request: {path}")


def validate(api, **changes):
    arguments = {
        "ref": f"refs/heads/release/{TAG}",
        "sha": COMMIT,
        "checked_out_sha": COMMIT,
        "pubspec": "name: viewer\nversion: 1.0.67+67\n",
    }
    arguments.update(changes)
    return validate_release(api, **arguments)


class PrepareReleaseTests(unittest.TestCase):
    def test_release_branch_and_tag_resolve_to_the_same_stable_version(self):
        self.assertEqual(resolve_tag(f"refs/heads/release/{TAG}"), TAG)
        self.assertEqual(resolve_tag(f"refs/tags/{TAG}"), TAG)

    def test_ordinary_branches_and_malformed_or_prerelease_tags_are_rejected(self):
        for ref in (
            "refs/heads/master",
            "refs/heads/feature/v1.0.67",
            "refs/heads/release/v01.0.67",
            "refs/heads/release/v1.0.67/extra",
            "refs/tags/v1.0.67-rc.1",
            "refs/tags/v1.0.67$(echo bad)",
            "refs/tags/v1.0.67\ntag=other",
        ):
            with self.subTest(ref=ref), self.assertRaises(ReleaseError):
                resolve_tag(ref)

    def test_pubspec_accepts_quotes_and_requires_positive_build(self):
        self.assertEqual(parse_version("version: '1.0.67+67' # stable\n"), ("1.0.67", 67))
        for value in ("1.0.67", "1.0.67+0", "1.0.67+-1", "1.0.67+abc", "1.0.67-rc.1+67"):
            with self.subTest(value=value), self.assertRaises(ReleaseError):
                parse_version(f"version: {value}\n")
        with self.assertRaises(ReleaseError):
            parse_version("version: 1.0.67+67\nversion: 1.0.68+68\n")

    def test_verified_master_commit_produces_metadata(self):
        api = FakeGitHub()
        result = validate(api)
        self.assertEqual((result.tag, result.sha, result.build), (TAG, COMMIT, 67))
        self.assertFalse(result.tag_exists)
        self.assertIn("head_sha=" + COMMIT, api.calls[1])
        self.assertIn("event=push", api.calls[1])
        self.assertIn("branch=master", api.calls[1])

    def test_version_mismatch_fails_before_api_reads(self):
        api = FakeGitHub()
        with self.assertRaisesRegex(ReleaseError, "exactly match"):
            validate(api, pubspec="version: 1.0.68+68\n")
        self.assertEqual(api.calls, [])

    def test_checkout_must_be_the_triggering_commit(self):
        for changes in ({"checked_out_sha": OTHER_COMMIT}, {"sha": "main"}):
            with self.subTest(changes=changes), self.assertRaisesRegex(ReleaseError, "checkout"):
                validate(FakeGitHub(), **changes)

    def test_master_may_have_advanced_after_the_release_commit(self):
        api = FakeGitHub()
        api.comparison["status"] = "ahead"
        self.assertEqual(validate(api).sha, COMMIT)

    def test_unmerged_or_diverged_commit_is_rejected(self):
        for status, merge_base in (("behind", COMMIT), ("diverged", OTHER_COMMIT), ("ahead", OTHER_COMMIT)):
            api = FakeGitHub()
            api.comparison = {"status": status, "merge_base_commit": {"sha": merge_base}}
            with self.subTest(status=status), self.assertRaisesRegex(ReleaseError, "not been merged"):
                validate(api)

    def test_ci_must_match_exact_sha_master_and_push_event(self):
        for field, value in (("head_sha", OTHER_COMMIT), ("event", "pull_request"), ("head_branch", "feature")):
            api = FakeGitHub()
            api.runs[0][field] = value
            with self.subTest(field=field), self.assertRaisesRegex(ReleaseError, "No CI push run"):
                validate(api)

    def test_missing_pending_failed_or_cancelled_ci_blocks_publication(self):
        api = FakeGitHub()
        api.runs = []
        with self.assertRaisesRegex(ReleaseError, "No CI push run"):
            validate(api)
        for status, conclusion in (("in_progress", None), ("completed", "failure"), ("completed", "cancelled")):
            api = FakeGitHub()
            api.runs[0].update(status=status, conclusion=conclusion)
            with self.subTest(conclusion=conclusion), self.assertRaisesRegex(ReleaseError, "not successful"):
                validate(api)

    def test_old_success_does_not_hide_a_newer_failure(self):
        api = FakeGitHub()
        newer = deepcopy(api.runs[0])
        newer.update(id=124, conclusion="failure")
        api.runs.append(newer)
        with self.assertRaisesRegex(ReleaseError, "not successful"):
            validate(api)

    def test_existing_lightweight_tag_must_match_commit(self):
        api = FakeGitHub()
        api.ref = {"object": {"type": "commit", "sha": COMMIT}}
        self.assertTrue(validate(api, ref=f"refs/tags/{TAG}").tag_exists)
        api.ref["object"]["sha"] = OTHER_COMMIT
        with self.assertRaisesRegex(ReleaseError, "different commit"):
            validate(api)

    def test_annotated_tags_are_dereferenced_before_comparison(self):
        api = FakeGitHub()
        api.ref = {"object": {"type": "tag", "sha": TAG_OBJECT}}
        api.tag_objects[TAG_OBJECT] = {"object": {"type": "commit", "sha": COMMIT}}
        self.assertTrue(validate(api).tag_exists)
        api.tag_objects[TAG_OBJECT]["object"]["sha"] = OTHER_COMMIT
        with self.assertRaisesRegex(ReleaseError, "different commit"):
            validate(api)

    def test_final_verification_requires_a_real_tag(self):
        with self.assertRaisesRegex(ReleaseError, "must exist"):
            validate(FakeGitHub(), require_tag=True)

    def test_existing_release_is_rejected_even_if_tag_matches(self):
        api = FakeGitHub()
        api.ref = {"object": {"type": "commit", "sha": COMMIT}}
        for draft in (False, True):
            api.release_pages = {1: [{"id": 42, "tag_name": TAG, "draft": draft}]}
            with self.subTest(draft=draft), self.assertRaisesRegex(ReleaseError, "not overwritten"):
                validate(api)

    def test_published_and_draft_releases_on_later_pages_are_rejected(self):
        for draft in (False, True):
            api = FakeGitHub()
            api.release_pages = {
                1: [{"tag_name": f"v0.0.{index}", "draft": False} for index in range(RELEASE_PAGE_SIZE)],
                2: [{"id": 42, "tag_name": TAG, "draft": draft}],
            }
            with self.subTest(draft=draft), self.assertRaisesRegex(ReleaseError, "not overwritten"):
                validate(api)
            self.assertIn("/releases?per_page=100&page=2", api.calls)

    def test_no_exact_tag_match_is_accepted_after_all_release_pages(self):
        api = FakeGitHub()
        api.release_pages = {
            1: [{"tag_name": f"v0.0.{index}", "draft": False} for index in range(RELEASE_PAGE_SIZE)],
            2: [
                {"tag_name": "v1.0.670", "draft": True},
                {"tag_name": "v1.0.67-rc.1", "draft": False},
                {"tag_name": "release/v1.0.67", "draft": True},
            ],
        }
        self.assertEqual(validate(api).tag, TAG)
        self.assertIn("/releases?per_page=100&page=2", api.calls)
        self.assertNotIn("/releases?per_page=100&page=3", api.calls)

    def test_invalid_release_list_fails_closed_on_any_page(self):
        for response in (None, {}, "not a list", [None], [{}], [{"tag_name": None}]):
            for page in (1, 2):
                api = FakeGitHub()
                api.release_pages = {
                    1: [{"tag_name": "v0.0.1"} for _ in range(RELEASE_PAGE_SIZE)],
                    page: response,
                }
                with self.subTest(response=response, page=page), self.assertRaisesRegex(ReleaseError, "invalid release list"):
                    validate(api)

    def test_release_listing_pagination_limit_fails_closed(self):
        api = FakeGitHub()
        api.release_pages = {
            page: [{"tag_name": "v0.0.1"} for _ in range(RELEASE_PAGE_SIZE)]
            for page in range(1, MAX_RELEASE_PAGES + 1)
        }
        with self.assertRaisesRegex(ReleaseError, "pagination limit"):
            validate(api)
        self.assertIn(f"/releases?per_page=100&page={MAX_RELEASE_PAGES}", api.calls)
        self.assertNotIn(f"/releases?per_page=100&page={MAX_RELEASE_PAGES + 1}", api.calls)

    def test_final_check_detects_a_tag_or_release_created_during_build(self):
        api = FakeGitHub()
        validate(api)
        api.ref = {"object": {"type": "commit", "sha": OTHER_COMMIT}}
        with self.assertRaisesRegex(ReleaseError, "different commit"):
            validate(api, require_tag=True)
        api.ref["object"]["sha"] = COMMIT
        api.release_pages = {1: [{"id": 42, "tag_name": TAG, "draft": True}]}
        with self.assertRaisesRegex(ReleaseError, "not overwritten"):
            validate(api, require_tag=True)

    def test_api_missing_resource_does_not_suppress_permission_errors(self):
        api = GitHubReader("example/viewer", "test-token")
        with patch("prepare_release.urlopen", side_effect=HTTPError("url", 404, "Not Found", {}, None)):
            self.assertIsNone(api.get("/git/ref/tags/v1.0.67", missing_ok=True))
        with patch("prepare_release.urlopen", side_effect=HTTPError("url", 403, "Forbidden", {}, None)):
            with self.assertRaisesRegex(ReleaseError, "HTTP 403"):
                api.get("/git/ref/tags/v1.0.67", missing_ok=True)


    def test_release_guide_does_not_use_git_or_github(self):
        with patch.object(prepare_release, "GitHubReader", side_effect=AssertionError("network access")), patch.object(
            prepare_release.subprocess, "check_output", side_effect=AssertionError("git access"),
        ):
            self.assertEqual(prepare_release.main(["--guide"]), 0)


if __name__ == "__main__":
    unittest.main()

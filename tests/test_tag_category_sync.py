"""Offline regressions for retaining category pages before a later failure."""

import contextlib
import io
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from unittest.mock import MagicMock, patch

import requests

import view
from scripts import sync_tag_categories as categories
from scripts.tag_db import TagDB


def page(highest_id, count=1000):
    return [
        {"name": f"tag_{tag_id}", "id": tag_id, "category": 4, "post_count": 12}
        for tag_id in range(highest_id, highest_id - count, -1)
    ]


def response(tags):
    result = requests.Response()
    result.status_code = 200
    result._content = json.dumps(tags).encode("utf-8")
    return result


class CategorySyncRetentionTest(unittest.TestCase):
    def setUp(self):
        directory = self.enterContext(tempfile.TemporaryDirectory())
        self.database = TagDB(Path(directory) / "tags.db")
        self.addCleanup(self.database.close)
        self.assertEqual(self.database.count_tags(), 0)
        self.enterContext(patch.object(categories, "db", self.database))
        self.enterContext(patch.object(categories.time, "sleep"))
        self.enterContext(patch.object(view, "request_limiter", contextlib.nullcontext()))
        self.output = self.enterContext(contextlib.redirect_stdout(io.StringIO()))
        self.session = MagicMock(spec=requests.Session)

    def failing_second_page(self):
        failure = requests.ConnectionError("second page unavailable")
        # Exercise fetch_page/safe_get rather than mocking their new exception
        # contract. No real requests, sleeps or repository database are used.
        self.session.get.side_effect = [response(page(1000))] + [failure] * 5
        return failure

    def assert_committed_rows(self, expected):
        # Open a separate connection so pending, uncommitted changes do not
        # count as retention of successfully fetched rows.
        with sqlite3.connect(self.database.path) as connection:
            self.assertEqual(connection.execute("SELECT count(*) FROM tags").fetchone()[0], expected)

    def test_second_page_failure_commits_pending_rows_and_preserves_original_error(self):
        failure = self.failing_second_page()
        with self.assertRaises(requests.ConnectionError) as caught:
            categories.sync_category(self.session, 4, delay=0, limit=0)

        self.assertIs(caught.exception, failure)
        self.assertEqual(self.session.get.call_count, 6)
        self.assertEqual(self.session.get.call_args.kwargs["params"]["search[id_lt]"], 1)
        self.assert_committed_rows(1000)
        stored = self.database.get_tag("tag_1000")
        self.assertEqual(stored["tag_info"], {
            "id": 1000, "name": "tag_1000", "category": 4, "post_count": 12,
        })

    def test_cli_reports_failure_after_retaining_successful_page(self):
        self.failing_second_page()
        with patch.object(sys, "argv", ["categories", "--categories", "4", "--workers", "1"]), patch.object(
            categories, "create_session", return_value=self.session,
        ):
            self.assertEqual(categories.main(), 1)

        self.assertIn("character failed: second page unavailable", self.output.getvalue())
        self.assert_committed_rows(1000)

    def test_successful_paging_keeps_five_thousand_row_batches_and_final_flush(self):
        self.session.get.side_effect = [
            response(page(6000 - offset * 1000)) for offset in range(5)
        ] + [response(page(1000, count=17))]
        with patch.object(
            self.database, "upsert_tag_categories", wraps=self.database.upsert_tag_categories,
        ) as write:
            self.assertEqual(categories.sync_category(self.session, 4, delay=0, limit=0), 5017)

        self.assertEqual([len(call.args[0]) for call in write.call_args_list], [5000, 17])
        self.assertEqual(
            [call.kwargs["params"].get("search[id_lt]") for call in self.session.get.call_args_list],
            [None, 5001, 4001, 3001, 2001, 1001],
        )
        self.assert_committed_rows(5017)

    def test_failed_error_path_flush_propagates_database_error_with_request_context(self):
        failure = self.failing_second_page()
        disk_failure = sqlite3.OperationalError("disk full")
        with patch.object(self.database, "upsert_tag_categories", side_effect=disk_failure) as write:
            with self.assertRaises(sqlite3.OperationalError) as caught:
                categories.sync_category(self.session, 4, delay=0, limit=0)

        self.assertIs(caught.exception, disk_failure)
        self.assertIs(caught.exception.__context__, failure)
        write.assert_called_once()
        self.assertEqual(self.database.count_tags(), 0)


if __name__ == "__main__":
    unittest.main()

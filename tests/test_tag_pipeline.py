"""Regression tests for the tag pipeline's paging and queue state."""

import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

from scripts import tag_pipeline
from scripts.batch_sync_tags import TagRecord
from scripts.tag_db import TagDB


class FakeDB:
    def __init__(self, cursor):
        self.cursor = cursor.copy()
        self.queued = []
        self.saved = []
        self.fail_enqueue = False

    def load_cursor(self):
        return self.cursor.copy()

    def save_cursor(self, cursor):
        self.cursor = cursor.copy()
        self.saved.append(cursor.copy())

    def enqueue_many(self, rows):
        if self.fail_enqueue:
            raise RuntimeError("queue write failed")
        self.queued.extend(rows)
        return len(rows)

    def existing_tag_ids(self, ids):
        return set()


class TagPipelineCursorTest(unittest.TestCase):
    def setUp(self):
        self.args = SimpleNamespace(
            no_verify_ssl=False, api_limit=1000, retries=1, delay=0,
            from_id=None,
        )
        self.patches = [
            patch.object(tag_pipeline, "create_session", return_value=object()),
            patch.object(tag_pipeline, "log"),
            patch.object(tag_pipeline.time, "sleep"),
        ]
        for item in self.patches:
            item.start()
            self.addCleanup(item.stop)

    def test_incremental_only_fetches_outside_saved_bounds(self):
        fake_db = FakeDB({"min_id": 10, "max_id": 20})
        pages = {
            ("id_asc", 20): [TagRecord("new1", 21), TagRecord("new2", 22)],
            ("id_asc", 22): [],
            ("id_desc", 10): [TagRecord("old2", 9), TagRecord("old1", 8)],
            ("id_desc", 8): [],
        }
        calls = []

        def fetch(_session, *, order, cursor_id, **_kwargs):
            calls.append((order, cursor_id))
            return pages[order, cursor_id]

        with patch.object(tag_pipeline, "db", fake_db), patch.object(
            tag_pipeline, "fetch_tags_from_api_page", side_effect=fetch,
        ):
            tag_pipeline.run_list_incremental(self.args)

        self.assertEqual(calls, list(pages))
        self.assertEqual([row[0] for row in fake_db.queued], [21, 22, 9, 8])
        self.assertEqual(fake_db.cursor, {"min_id": 8, "max_id": 22})
        self.assertEqual(len(fake_db.saved), 2)

    def test_first_full_scan_saves_cursor_for_next_incremental_run(self):
        fake_db = FakeDB({})
        pages = {
            None: [TagRecord("new", 30), TagRecord("middle", 29)],
            29: [TagRecord("old", 28)],
            28: [],
        }

        def fetch(_session, *, order, cursor_id, **_kwargs):
            self.assertEqual(order, "id_desc")
            return pages[cursor_id]

        with patch.object(tag_pipeline, "db", fake_db), patch.object(
            tag_pipeline, "fetch_tags_from_api_page", side_effect=fetch,
        ):
            tag_pipeline.run_list_incremental(self.args)

        self.assertEqual(fake_db.cursor, {"min_id": 28, "max_id": 30})
        self.assertEqual([row[0] for row in fake_db.queued], [30, 29, 28])
        self.assertEqual(len(fake_db.saved), 2)

    def test_failed_queue_write_does_not_advance_cursor(self):
        fake_db = FakeDB({"min_id": 10, "max_id": 20})
        fake_db.fail_enqueue = True
        with patch.object(tag_pipeline, "db", fake_db), patch.object(
            tag_pipeline, "fetch_tags_from_api_page",
            return_value=[TagRecord("new", 21)],
        ):
            with self.assertRaisesRegex(RuntimeError, "queue write failed"):
                tag_pipeline.run_list_incremental(self.args)

        self.assertEqual(fake_db.cursor, {"min_id": 10, "max_id": 20})
        self.assertEqual(fake_db.saved, [])


class TagPipelineConsumerTest(unittest.TestCase):
    def setUp(self):
        self.db = MagicMock()
        self.db.get_sync_status.return_value = None
        self.patches = [
            patch.object(tag_pipeline, "db", self.db),
            patch.object(tag_pipeline, "log"),
            patch.object(tag_pipeline.view, "sync_data", return_value={"tag": "test"}),
        ]
        for item in self.patches:
            item.start()
            self.addCleanup(item.stop)

    def test_successful_stored_tag_is_skipped_with_point_lookup(self):
        self.db.get_sync_status.return_value = {"status": "success"}
        self.db.has_tag.return_value = True

        result = tag_pipeline.sync_queue_tag((1, "test", None), force=False)

        self.assertEqual(result, ("skipped", 1))
        self.db.list_sync_status.assert_not_called()
        tag_pipeline.view.sync_data.assert_not_called()

    def test_success_status_without_tag_is_resynced(self):
        self.db.get_sync_status.return_value = {"status": "success"}
        self.db.has_tag.return_value = False

        result = tag_pipeline.sync_queue_tag((1, "test", None), force=False)

        self.assertEqual(result, ("synced", 1))
        self.db.upsert_tag.assert_called_once_with({"tag": "test"})
        self.db.set_sync_status.assert_called_once()
        self.assertEqual(self.db.set_sync_status.call_args.args[:2], ("test", "success"))

    def test_failed_db_write_does_not_mark_tag_as_success(self):
        self.db.upsert_tag.side_effect = RuntimeError("disk full")

        result = tag_pipeline.sync_queue_tag((1, "test", None), force=False)

        self.assertEqual(result, ("failed", 1))
        self.assertEqual(self.db.set_sync_status.call_args.args[:2], ("test", "failed"))

    def test_fifth_failure_blocks_future_retries(self):
        self.db.get_sync_status.return_value = {"status": "failed", "failures": 4}
        self.db.upsert_tag.side_effect = RuntimeError("write failed")

        result = tag_pipeline.sync_queue_tag((1, "test", None), force=False)

        self.assertEqual(result, ("blocked", 1))
        self.assertEqual(self.db.set_sync_status.call_args.args[:2], ("test", "blocked"))


class TagDBQueueTest(unittest.TestCase):
    def test_failed_items_retry_next_run_except_blocked_tags(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            db = TagDB(Path(temp_dir) / "tags.db")
            try:
                db.enqueue_many([(1, "retry", None), (2, "blocked", None)])
                db.mark_done(1, "failed")
                db.mark_done(2, "failed")
                db.set_sync_status("blocked", "blocked", failures=5)

                self.assertEqual(db.requeue_failed(), 1)
                self.assertEqual(db.queue_status_counts(), {"pending": 1, "failed": 1})
                self.assertEqual(db.requeue_failed(), 0)
            finally:
                db.close()

    def test_has_tag_checks_indexed_tag_record(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            db = TagDB(Path(temp_dir) / "tags.db")
            try:
                self.assertFalse(db.has_tag("test"))
                db.upsert_tag({"tag": "test"})
                self.assertTrue(db.has_tag("test"))
            finally:
                db.close()


if __name__ == "__main__":
    unittest.main()

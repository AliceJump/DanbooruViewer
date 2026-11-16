"""Offline regressions for data retention, queue retries, and network failures."""

import contextlib
from datetime import datetime, timezone
import hashlib
import io
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import MagicMock, patch
from zipfile import ZipFile

import requests

import view
from scripts import batch_sync_tags as batch
from scripts import build_completion_zip as exporter
from scripts import migrate_json_to_db as migration
from scripts import restore_latest_tag_json as restore
from scripts import sync_tag_categories as categories
from scripts import tag_pipeline as pipeline
from scripts import update_wiki_aliases as wiki_sync
from scripts.tag_db import SCHEMA, TagDB, merge_import_payload


def payload(tag="sample", tag_id=1, category=4):
    return {
        "tag": tag,
        "updated_at": "2026-01-01T00:00:00+00:00",
        "tag_info": {"id": tag_id, "name": tag, "category": category, "post_count": 12},
        "wiki": {"other_names": ["旧名称"]},
        "aliases": ["old_alias"],
        "completion_candidates": [
            {"value": tag, "insert_value": tag, "source": "tag", "score": 100},
        ],
    }


class TemporaryDatabaseTest(unittest.TestCase):
    def setUp(self):
        directory = self.enterContext(tempfile.TemporaryDirectory())
        self.root = Path(directory)
        self.db = TagDB(self.root / "tags.db")
        self.addCleanup(self.db.close)
        self.enterContext(contextlib.redirect_stdout(io.StringIO()))


class MigrationIntegrityTest(TemporaryDatabaseTest):
    def setUp(self):
        super().setUp()
        self.cache, self.raw, self.assets = [self.root / name for name in ("cache", "raw", "assets")]
        for directory in (self.cache, self.raw, self.assets):
            directory.mkdir()
        for name, value in (("CACHE_DIR", self.cache), ("DOT_CACHE_DIR", self.raw),
                            ("ASSET_DIR", self.assets), ("db", self.db)):
            self.enterContext(patch.object(migration, name, value))
        self.enterContext(patch.object(sys, "argv", ["migrate_json_to_db"]))

    def test_invalid_json_keeps_every_source_and_reports_failure(self):
        bad = self.raw / "bad.json"
        good = self.raw / "good.json"
        bad.write_text("{broken", encoding="utf-8")
        good.write_text(json.dumps(payload()), encoding="utf-8")
        self.assertEqual(migration.main(), 1)
        self.assertTrue(bad.exists())
        self.assertTrue(good.exists())
        self.assertEqual(self.db.count_tags(), 0)

    def test_failed_database_write_preserves_source(self):
        source = self.raw / "sample.json"
        source.write_text(json.dumps(payload()), encoding="utf-8")
        with patch.object(self.db, "import_tags", side_effect=sqlite3.OperationalError("disk full")):
            self.assertEqual(migration.main(), 1)
        self.assertTrue(source.exists())
        self.assertEqual(self.db.count_tags(), 0)

    def test_invalid_state_json_is_retained(self):
        source = self.cache / "successful_tags.json"
        source.write_text(json.dumps({"unexpected": True}), encoding="utf-8")
        self.assertEqual(migration.main(), 1)
        self.assertTrue(source.exists())

    def test_conflicting_mirrors_are_retained(self):
        first, second = self.raw / "sample.json", self.assets / "sample.json"
        first.write_text(json.dumps(payload()), encoding="utf-8")
        changed = payload()
        changed["completion_candidates"] = []
        second.write_text(json.dumps(changed), encoding="utf-8")
        self.assertEqual(migration.main(), 1)
        self.assertTrue(first.exists())
        self.assertTrue(second.exists())

    def test_successful_compact_import_preserves_metadata_before_deleting_source(self):
        self.db.upsert_tag(payload())
        source = self.raw / "sample.json"
        source.write_text(json.dumps({"tag": "sample", "completion_candidates": []}), encoding="utf-8")
        self.assertEqual(migration.main(), 0)
        self.assertFalse(source.exists())
        stored = self.db.get_tag("sample")
        self.assertEqual(stored["tag_info"], payload()["tag_info"])
        self.assertEqual(stored["completion_candidates"], [])

    def test_bulk_database_error_rolls_back_earlier_rows(self):
        bad = payload("bad", 2)
        bad["tag_info"]["category"] = []
        with self.assertRaises(sqlite3.Error):
            self.db.upsert_tags_many([payload(), bad])
        self.assertEqual(self.db.count_tags(), 0)

    def test_cleanup_failure_retains_source_and_reports_nonzero(self):
        source = self.raw / "sample.json"
        source.write_text(json.dumps(payload()), encoding="utf-8")
        with patch.object(Path, "unlink", side_effect=PermissionError("file is in use")), contextlib.redirect_stdout(
            io.StringIO(),
        ) as output:
            self.assertEqual(migration.main(), 1)
        self.assertTrue(source.exists())
        self.assertEqual(self.db.count_tags(), 1)
        self.assertIn("cleanup is incomplete", output.getvalue())
        self.assertNotIn("fully migrated", output.getvalue())

    def test_changed_source_is_not_deleted_after_import(self):
        source = self.raw / "sample.json"
        original = payload()
        source.write_text(json.dumps(original), encoding="utf-8")
        updated = payload()
        updated["completion_candidates"].append(
            {"value": "new_alias", "insert_value": "sample", "source": "alias", "score": 85},
        )
        cleanup = migration.delete_sources

        def update_before_cleanup(imported_sources):
            source.write_text(json.dumps(updated), encoding="utf-8")
            return cleanup(imported_sources)

        with patch.object(migration, "delete_sources", side_effect=update_before_cleanup):
            self.assertEqual(migration.main(), 1)
        self.assertEqual(json.loads(source.read_text(encoding="utf-8")), updated)
        self.assertEqual(self.db.get_tag("sample")["completion_candidates"], original["completion_candidates"])

    def test_publication_between_verified_read_and_unlink_is_retained(self):
        source = self.raw / "sample.json"
        original = payload()
        source.write_text(json.dumps(original), encoding="utf-8")
        updated = payload()
        updated["completion_candidates"] = [{"value": "new", "insert_value": "sample"}]
        original_unlink = Path.unlink
        published = False

        def publish_before_unlink(path, *args, **kwargs):
            nonlocal published
            if path.name == source.name and not published:
                published = True
                view.save_sync_data("sample", updated)
            return original_unlink(path, *args, **kwargs)

        with patch.object(view, "CACHE_DIR", self.raw), patch.object(view, "ASSET_DIR", self.assets), patch.object(
            Path, "unlink", publish_before_unlink,
        ):
            self.assertEqual(migration.main(), 1)
        self.assertTrue(published)
        self.assertEqual(json.loads(source.read_text(encoding="utf-8")), view.compact_sync_payload(updated))
        self.assertEqual(self.db.get_tag("sample")["completion_candidates"], original["completion_candidates"])

    def test_changed_claim_never_overwrites_a_recreated_source(self):
        source = self.raw / "sample.json"
        source.write_text(json.dumps(payload()), encoding="utf-8")
        changed, newest = payload(), payload()
        changed["completion_candidates"] = [{"value": "changed"}]
        newest["completion_candidates"] = [{"value": "newest"}]
        cleanup = migration.delete_sources
        original_read = Path.read_bytes

        def read_claim_then_recreate(path):
            data = original_read(path)
            if path.name == source.name and path != source:
                view.save_sync_data("sample", newest)
            return data

        def change_before_claim(imported_sources):
            source.write_text(json.dumps(changed), encoding="utf-8")
            with patch.object(Path, "read_bytes", read_claim_then_recreate):
                return cleanup(imported_sources)

        with patch.object(view, "CACHE_DIR", self.raw), patch.object(view, "ASSET_DIR", self.assets), patch.object(
            migration, "delete_sources", side_effect=change_before_claim,
        ), contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(migration.main(), 1)
        self.assertEqual(json.loads(source.read_text(encoding="utf-8")), view.compact_sync_payload(newest))
        claims = list(self.raw.glob(".migration-cleanup-*/sample.json"))
        self.assertEqual(len(claims), 1)
        self.assertEqual(json.loads(claims[0].read_text(encoding="utf-8")), changed)
        self.assertIn(str(claims[0]), output.getvalue())
        self.assertEqual(self.db.get_tag("sample")["completion_candidates"], payload()["completion_candidates"])

    def test_unavailable_hard_links_leave_the_changed_claim_recoverable(self):
        source = self.raw / "sample.json"
        source.write_text(json.dumps(payload()), encoding="utf-8")
        changed = payload()
        changed["completion_candidates"] = []
        cleanup = migration.delete_sources

        def change_before_claim(imported_sources):
            source.write_text(json.dumps(changed), encoding="utf-8")
            return cleanup(imported_sources)

        with patch.object(migration, "delete_sources", side_effect=change_before_claim), patch(
            "os.link", side_effect=OSError("hard links unavailable on this volume"),
        ), contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(migration.main(), 1)
        claims = list(self.raw.glob(".migration-cleanup-*/sample.json"))
        self.assertEqual(len(claims), 1)
        self.assertEqual(json.loads(claims[0].read_text(encoding="utf-8")), changed)
        self.assertIn(str(claims[0]), output.getvalue())

    def test_failed_claim_rename_keeps_source_in_place(self):
        source = self.raw / "sample.json"
        source.write_text(json.dumps(payload()), encoding="utf-8")
        with patch.object(Path, "rename", side_effect=PermissionError("source is open without delete sharing")):
            self.assertEqual(migration.main(), 1)
        self.assertEqual(json.loads(source.read_text(encoding="utf-8")), payload())
        self.assertFalse(list(self.raw.glob(".migration-cleanup-*")))
        self.assertEqual(self.db.count_tags(), 1)

    def test_interruption_restores_claim_before_propagating(self):
        source = self.raw / "sample.json"
        source.write_text(json.dumps(payload()), encoding="utf-8")
        original_read = Path.read_bytes

        def interrupt_claim_read(path):
            if path.name == source.name and path != source:
                raise KeyboardInterrupt()
            return original_read(path)

        with patch.object(Path, "read_bytes", interrupt_claim_read), contextlib.redirect_stdout(io.StringIO()) as output:
            with self.assertRaises(KeyboardInterrupt):
                migration.main()
        self.assertEqual(json.loads(source.read_text(encoding="utf-8")), payload())
        self.assertIn(str(source), output.getvalue())
        self.assertFalse(list(self.raw.glob(".migration-cleanup-*")))


class LegacyFilePublicationTest(TemporaryDatabaseTest):
    def test_json_writers_publish_complete_files_without_mutating_old_paths(self):
        cache, assets = self.root / "legacy", self.root / "assets"
        cache.mkdir()
        assets.mkdir()
        source, mirror, metadata = cache / "sample.json", assets / "sample.json", cache / "sync_metadata.json"
        for path in (source, mirror, metadata):
            path.write_text('{"old": true}', encoding="utf-8")
        previous_replace = Path.replace
        published = []

        def replace_complete_file(temporary, destination):
            destination = Path(destination)
            self.assertNotEqual(temporary, destination)
            self.assertEqual(temporary.parent, destination.parent)
            self.assertEqual(json.loads(destination.read_text(encoding="utf-8")), {"old": True})
            json.loads(temporary.read_text(encoding="utf-8"))
            published.append(destination)
            return previous_replace(temporary, destination)

        with patch.object(view, "CACHE_DIR", cache), patch.object(view, "ASSET_DIR", assets), patch.object(
            Path, "replace", replace_complete_file,
        ):
            view.save_sync_data("sample", payload())
            view.save_sync_metadata({"sample": {"last_sync": "new"}})
        self.assertCountEqual(published, [source, mirror, metadata])
        self.assertEqual(json.loads(source.read_text(encoding="utf-8")), view.compact_sync_payload(payload()))
        self.assertEqual(source.read_bytes(), mirror.read_bytes())
        self.assertEqual(json.loads(metadata.read_text(encoding="utf-8")), {"sample": {"last_sync": "new"}})
        self.assertFalse(list(cache.glob("*.tmp")) + list(assets.glob("*.tmp")))


class QueueIntegrityTest(TemporaryDatabaseTest):
    def setUp(self):
        super().setUp()
        self.enterContext(patch.object(pipeline, "db", self.db))
        self.enterContext(patch.object(pipeline, "log"))
        self.enterContext(patch.object(pipeline, "create_session", return_value=object()))

    def test_resync_months_requeues_a_completed_tag_and_refreshes_without_force(self):
        self.db.upsert_tag(payload())
        self.db.set_sync_status("sample", "success")
        self.db.enqueue_many([(1, "sample", None)])
        self.db.mark_done(1, "synced")
        args = SimpleNamespace(no_verify_ssl=False, from_id=None, api_limit=1000, retries=1, delay=0)
        record = batch.TagRecord("sample", 1, datetime.now(timezone.utc).isoformat())
        with patch.object(pipeline, "fetch_tags_from_api_page", side_effect=[[record], []]):
            pipeline.run_list_resync_months(args, 1)
        claimed = self.db.claim_batch(claimer="test")
        self.assertEqual([claim[:3] for claim in claimed], [(1, "sample", record.created_at)])
        with patch.object(view, "sync_data", return_value=payload()) as fetch:
            self.assertEqual(pipeline.sync_queue_tag(claimed[0], force=False), ("synced", 1))
        fetch.assert_called_once()

    def test_resync_preserves_unexpired_claim_and_last_success(self):
        self.db.set_sync_status("sample", "success")
        self.db.enqueue_many([(1, "sample", None)])
        self.db.claim_batch(claimer="active-worker")
        self.assertEqual(self.db.requeue_many([(1, "sample", None)]), 0)
        self.assertEqual(self.db.queue_count("claimed"), 1)
        self.assertEqual(self.db.get_sync_status("sample")["status"], "success")
        owner = self.db.conn.execute("SELECT claimed_by FROM sync_queue").fetchone()[0]
        self.assertEqual(owner, "active-worker")

    def test_resync_can_requeue_an_expired_claim(self):
        self.db.enqueue_many([(1, "sample", None)])
        self.db.claim_batch(claimer="old-worker")
        self.db.conn.execute("UPDATE sync_queue SET claimed_at=0")
        self.db.conn.commit()
        self.assertEqual(self.db.requeue_many([(1, "sample", None)]), 1)
        self.assertEqual(self.db.queue_count("pending"), 1)

    def test_incremental_enqueue_does_not_repeat_completed_work(self):
        self.db.enqueue_many([(1, "sample", None)])
        self.db.mark_done(1, "synced")
        self.assertEqual(self.db.enqueue_many([(1, "sample", None)]), 0)
        self.assertEqual(self.db.queue_count("synced"), 1)

    def run_consumer(self):
        args = SimpleNamespace(rate=5, no_verify_ssl=False, workers=1, limit=0,
                               idle_stop=1, poll=0, force=False)
        with patch.object(view, "set_request_rate"):
            return pipeline.run_sync(args)

    def test_failed_sync_is_not_a_successful_process(self):
        self.db.enqueue_many([(1, "sample", None)])
        with patch.object(view, "sync_data", side_effect=requests.ConnectionError("offline")):
            self.assertEqual(self.run_consumer(), 1)
        self.assertEqual(self.db.queue_count("failed"), 1)

    def test_worker_database_error_reaches_process_result(self):
        self.db.enqueue_many([(1, "sample", None)])
        with patch.object(view, "sync_data", return_value=payload()), patch.object(
            self.db, "complete_claim", side_effect=sqlite3.OperationalError("disk full"),
        ):
            self.assertEqual(self.run_consumer(), 1)
        self.assertEqual(self.db.queue_count("claimed"), 1)

    def test_expired_worker_success_cannot_replace_new_owner_result(self):
        self.db.enqueue_many([(1, "sample", None)])
        old_claim = self.db.claim_batch(claimer="same-worker-name")[0]
        other = TagDB(self.db.path)
        self.addCleanup(other.close)
        newer = payload()
        newer["completion_candidates"][0]["value"] = "new-response"

        def finish_new_owner(*_args, **_kwargs):
            other.conn.execute("UPDATE sync_queue SET claimed_at=0")
            other.conn.commit()
            other.requeue_many([(1, "sample", None)])
            new_claim = other.claim_batch(claimer="same-worker-name")[0]
            with patch.object(pipeline, "db", other), patch.object(view, "sync_data", return_value=newer):
                self.assertEqual(pipeline.sync_queue_tag(new_claim, force=False), ("synced", 1))
            return payload()

        with patch.object(view, "sync_data", side_effect=finish_new_owner):
            self.assertEqual(pipeline.sync_queue_tag(old_claim, force=False), ("stale", 1))
        self.assertEqual(self.db.get_tag("sample")["completion_candidates"], newer["completion_candidates"])
        self.assertEqual(self.db.get_sync_status("sample")["status"], "success")
        self.assertEqual(self.db.queue_count("synced"), 1)

    def test_expired_worker_failure_cannot_replace_active_claim_or_block_it(self):
        for failures in (0, 4):
            with self.subTest(previous_failures=failures):
                self.db.drop_queue()
                self.db.set_sync_status("sample", "pending")
                self.db.enqueue_many([(1, "sample", None)])
                old_claim = self.db.claim_batch(claimer="same-worker-name")[0]
                other = TagDB(self.db.path)
                self.addCleanup(other.close)

                def reclaim_then_fail(*_args, **_kwargs):
                    other.conn.execute("UPDATE sync_queue SET claimed_at=0")
                    other.conn.commit()
                    other.requeue_many([(1, "sample", None)])
                    other.claim_batch(claimer="same-worker-name")
                    other.set_sync_status("sample", "failed", reason="new-owner", failures=failures)
                    raise requests.ConnectionError("old-response-failure")

                with patch.object(view, "sync_data", side_effect=reclaim_then_fail):
                    self.assertEqual(pipeline.sync_queue_tag(old_claim, force=False), ("stale", 1))
                status = self.db.get_sync_status("sample")
                self.assertEqual((status["status"], status["reason"], status["failures"]),
                                 ("failed", "new-owner", failures))
                self.assertEqual(self.db.queue_count("claimed"), 1)

    def test_same_claimer_and_timestamp_do_not_return_an_earlier_batch(self):
        self.db.enqueue_many([(1, "first", None), (2, "second", None)])
        other = TagDB(self.db.path)
        self.addCleanup(other.close)
        with patch("time.time", return_value=1000):
            first = self.db.claim_batch(limit=1, claimer="same-process")[0]
            second = other.claim_batch(limit=1, claimer="same-process")[0]
        self.assertEqual((first.tag_id, second.tag_id), (1, 2))
        self.assertNotEqual(first.token, second.token)
        self.assertEqual(self.db.queue_count("claimed"), 2)

    def test_success_commit_rolls_back_all_three_tables_at_each_late_failure(self):
        self.db.upsert_tag(payload())
        self.db.set_sync_status("sample", "success", last_sync_time="old-success")
        self.db.enqueue_many([(1, "sample", None)])
        claim = self.db.claim_batch()[0]
        other = TagDB(self.db.path)
        self.addCleanup(other.close)
        tables = ("tags", "sync_status", "sync_queue")

        def snapshot(database):
            return {table: database.conn.execute(f"SELECT * FROM {table}").fetchall() for table in tables}

        before = snapshot(other)
        newer = payload(category=0)
        for operation in ("INSERT ON sync_status", "UPDATE OF status ON sync_queue"):
            with self.subTest(failure=operation):
                self.db.conn.execute(
                    f"CREATE TEMP TRIGGER fail_commit BEFORE {operation} "
                    "BEGIN SELECT RAISE(ABORT, 'forced commit failure'); END"
                )
                with self.assertRaisesRegex(sqlite3.IntegrityError, "forced commit failure"):
                    self.db.complete_claim(claim, "synced", payload=newer)
                self.assertFalse(self.db.conn.in_transaction)
                self.assertEqual(snapshot(self.db), before)
                self.assertEqual(snapshot(other), before)
                self.db.conn.execute("DROP TRIGGER fail_commit")
        self.assertEqual(self.db.complete_claim(claim, "synced", payload=newer), "synced")
        self.assertEqual(other.get_tag("sample")["tag_info"]["category"], 0)
        self.assertEqual(other.queue_count("synced"), 1)

    def test_failed_completion_rolls_back_before_retrying_the_fifth_failure(self):
        self.db.upsert_tag(payload())
        self.db.set_sync_status("sample", "failed", failures=4, last_sync_time="last-success")
        self.db.enqueue_many([(1, "sample", None)])
        claim = self.db.claim_batch()[0]
        before = self.db.get_sync_status("sample")
        self.db.conn.execute(
            "CREATE TEMP TRIGGER fail_queue BEFORE UPDATE OF status ON sync_queue "
            "BEGIN SELECT RAISE(ABORT, 'queue unavailable'); END"
        )
        with self.assertRaisesRegex(sqlite3.IntegrityError, "queue unavailable"):
            self.db.complete_claim(claim, "failed", error="offline")
        self.assertEqual(self.db.get_sync_status("sample"), before)
        self.assertEqual(self.db.queue_count("claimed"), 1)
        self.db.conn.execute("DROP TRIGGER fail_queue")
        self.assertEqual(self.db.complete_claim(claim, "failed", error="offline"), "blocked")
        status = self.db.get_sync_status("sample")
        self.assertEqual(status["failures"], 5)
        self.assertEqual(status["last_sync_time"], "last-success")
        self.assertEqual(self.db.queue_count("blocked"), 1)


class ExportIntegrityTest(TemporaryDatabaseTest):
    def setUp(self):
        super().setUp()
        self.db.conn  # Initialize the temporary schema only.
        self.output = self.root / "completion.zip"
        self.manifest = self.root / "completion.manifest.json"
        for name, value in (
            ("TAG_DB", self.db.path), ("SEED_DB", self.root / "no-seed.db"),
            ("OUTPUT_FILE", self.output), ("TEMP_OUTPUT_FILE", self.root / "completion.zip.tmp"),
            ("MANIFEST_FILE", self.manifest), ("INDEX_FILE", self.root / "index.zip"),
            ("BOOTSTRAP_FILE", self.root / "bootstrap.json"),
        ):
            self.enterContext(patch.object(exporter, name, value))

    def write_legacy(self, candidates):
        with ZipFile(self.output, "w") as archive:
            archive.writestr(exporter.COMPACT_FILE, json.dumps(candidates))

    def test_current_tag_replaces_deleted_legacy_alias_but_retains_missing_tags(self):
        self.db.upsert_tag(payload())
        self.write_legacy([
            {"v": "sample", "i": "sample", "r": 100},
            {"v": "deleted_alias", "i": "sample", "r": 200},
            {"v": "legacy_only", "i": "legacy_only", "r": 100},
        ])
        result = exporter.build_suggestions()
        self.assertEqual(set(result), {("sample", "sample"), ("legacy_only", "legacy_only")})

    def test_category_placeholder_keeps_legacy_candidates_with_current_category(self):
        self.db.upsert_tag_categories([("sample", 1, 0, 12)])
        self.write_legacy([{"v": "alias", "i": "sample", "r": 85, "c": 4}])
        self.assertEqual(exporter.build_suggestions()[("alias", "sample")][4], 0)

    def test_successfully_synced_empty_list_does_not_resurrect_old_candidates(self):
        empty = payload()
        empty["completion_candidates"] = []
        self.db.upsert_tag(empty)
        self.db.set_sync_status("sample", "success")
        self.write_legacy([{"v": "sample", "i": "sample", "r": 100}])
        self.assertEqual(exporter.build_suggestions(), {})

    def test_empty_candidate_authority_survives_queued_and_failed_resync(self):
        empty = payload()
        empty["completion_candidates"] = []
        self.db.upsert_tag(empty)
        self.db.set_sync_status("sample", "success", last_sync_time="2026-01-01T00:00:00Z")
        self.write_legacy([{"v": "deleted_alias", "i": "sample", "r": 100}])
        self.assertEqual(exporter.build_suggestions(), {})
        self.db.requeue_many([(1, "sample", None)])
        self.assertEqual(exporter.build_suggestions(), {})
        self.db.set_sync_status("sample", "failed", failures=1)
        self.assertEqual(exporter.build_suggestions(), {})
        self.output.unlink()
        self.assertEqual(exporter.build_suggestions(), {})

    def test_empty_import_and_placeholder_merge_keep_distinct_authority(self):
        self.db.upsert_tag_categories([("sample", 1, 4, 12)])
        self.write_legacy([{"v": "legacy_alias", "i": "sample", "r": 100}])
        self.db.upsert_tags_many([
            merge_import_payload(self.db.get_tag("sample"), {"tag": "sample", "wiki": None})
        ])
        self.assertIn(("legacy_alias", "sample"), exporter.build_suggestions())
        before = exporter.db_fingerprint()
        self.db.upsert_tags_many([
            merge_import_payload(self.db.get_tag("sample"), {"tag": "sample", "completion_candidates": []})
        ])
        self.assertIsNone(self.db.get_sync_status("sample"))
        self.assertEqual(exporter.build_suggestions(), {})
        self.assertNotEqual(exporter.db_fingerprint(), before)

    def test_category_and_candidate_updates_invalidate_signature_without_timestamp_change(self):
        original = payload()
        self.db.upsert_tag(original)
        before = exporter.db_fingerprint()
        self.db.upsert_tag_categories([("sample", 1, 3, 12)])
        after = exporter.db_fingerprint()
        self.assertNotEqual(before, after)
        changed = payload(category=3)
        changed["completion_candidates"] = []
        self.db.upsert_tag(changed)
        self.assertNotEqual(after, exporter.db_fingerprint())
        self.assertEqual(self.db.get_tag("sample")["updated_at"], original["updated_at"])

    def test_export_signature_stabilizes_after_replacing_its_fallback_zip(self):
        self.db.upsert_tag(payload())
        args = SimpleNamespace(store=False, best=False, compresslevel=3, force=False, clean_legacy=False)
        with patch.object(exporter, "parse_args", return_value=args):
            exporter.main()
            with patch.object(exporter, "build_suggestions", side_effect=AssertionError("unexpected rebuild")):
                exporter.main()
            self.db.upsert_tag_categories([("sample", 1, 0, 12)])
            exporter.main()
        with ZipFile(self.output) as archive:
            candidates = json.loads(archive.read(exporter.COMPACT_FILE))
        self.assertEqual(candidates[0]["c"], 0)


class LegacyDatabaseCompatibilityTest(TemporaryDatabaseTest):
    def setUp(self):
        super().setUp()
        # The previous on-disk schema predates both new columns.
        legacy_schema = "\n".join(
            line for line in SCHEMA.splitlines()
            if "completion_authoritative" not in line and "claim_token" not in line
        )
        with sqlite3.connect(self.db.path) as conn:
            conn.executescript(legacy_schema)
            for tag, status, last_success in (
                ("complete", "success", None),
                ("pending_after_success", "pending", "2026-01-01T00:00:00Z"),
                ("placeholder", None, None),
                ("unknown_pending", "pending", None),
            ):
                conn.execute(
                    "INSERT INTO tags (name, slug, updated_at, completion_candidates) VALUES (?, ?, 'old', '[]')",
                    (tag, tag),
                )
                if status:
                    conn.execute(
                        "INSERT INTO sync_status (tag, status, last_sync_time) VALUES (?, ?, ?)",
                        (tag, status, last_success),
                    )
            conn.execute(
                "INSERT INTO sync_queue (tag_id, name, status, enqueued_at, claimed_by, claimed_at) "
                "VALUES (1, 'complete', 'claimed', 'old', 'old-process', 0)"
            )
        self.output = self.root / "legacy.zip"
        with ZipFile(self.output, "w") as archive:
            archive.writestr(exporter.COMPACT_FILE, json.dumps([
                {"v": tag, "i": tag, "r": 100}
                for tag in ("complete", "pending_after_success", "placeholder", "unknown_pending")
            ]))
        for name, value in (("TAG_DB", self.db.path), ("SEED_DB", self.root / "no-seed.db"),
                            ("OUTPUT_FILE", self.output)):
            self.enterContext(patch.object(exporter, name, value))

    def test_old_schema_export_is_read_only_and_matches_upgraded_fingerprint(self):
        before = self.db.path.read_bytes()
        expected = {("placeholder", "placeholder"), ("unknown_pending", "unknown_pending")}
        self.assertEqual(set(exporter.build_suggestions()), expected)
        fingerprint = exporter.db_fingerprint()
        self.assertEqual(self.db.path.read_bytes(), before)
        self.assertIsNone(self.db._conn)
        self.db.conn  # Upgrade only now, through the writable database API.
        self.assertEqual(set(exporter.build_suggestions()), expected)
        self.assertEqual(exporter.db_fingerprint(), fingerprint)

    def test_upgrade_recovers_prior_success_once_and_reclaims_old_tokenless_rows(self):
        flags = dict(self.db.conn.execute("SELECT name, completion_authoritative FROM tags"))
        self.assertEqual(flags, {"complete": 1, "pending_after_success": 1,
                                 "placeholder": 0, "unknown_pending": 0})
        claim = self.db.claim_batch(claimer="old-process")[0]
        self.assertTrue(claim.token)
        self.assertEqual(self.db.complete_claim(claim, "skipped"), "skipped")
        # A new status-only write cannot retroactively turn a placeholder into
        # a complete payload when a later connection opens the same schema.
        self.db.set_sync_status("placeholder", "success", last_sync_time="new-status-only")
        self.db.close()
        flags = dict(self.db.conn.execute("SELECT name, completion_authoritative FROM tags"))
        self.assertEqual(flags["placeholder"], 0)


class RestoreIntegrityTest(TemporaryDatabaseTest):
    def setUp(self):
        super().setUp()
        self.enterContext(patch.object(restore, "db", self.db))
        self.archive = self.root / "backup.zip"

    def write_archive(self, records):
        entries = []
        with ZipFile(self.archive, "w") as archive:
            for index, (tag, tag_id, data) in enumerate(records):
                blob = json.dumps(data).encode("utf-8")
                name = f"json/{index}.json"
                entry = {"tag": tag, "tag_id": tag_id, "slug": str(index), "file": name,
                         "size": len(blob), "sha256": hashlib.sha256(blob).hexdigest()}
                entries.append(entry)
                archive.writestr(name, blob)
            archive.writestr("manifest.json", json.dumps({"entries": entries}))

    def restore(self, dry_run=False):
        restore.restore_archive(self.archive, self.root / "unused", None, dry_run)

    def test_compact_restore_preserves_known_metadata(self):
        self.db.upsert_tag(payload())
        compact = {"tag": "sample", "completion_candidates": []}
        self.write_archive([("sample", 1, compact)])
        self.restore()
        restored = self.db.get_tag("sample")
        self.assertEqual(restored["tag_info"], payload()["tag_info"])
        self.assertEqual(restored["wiki"], payload()["wiki"])
        self.assertEqual(restored["aliases"], payload()["aliases"])
        self.assertEqual(restored["completion_candidates"], [])

    def test_manifest_id_recovers_identity_for_new_compact_record(self):
        self.write_archive([("sample", 1, {"tag": "sample", "completion_candidates": []})])
        self.restore()
        self.assertEqual(self.db.get_tag("sample")["tag_info"]["id"], 1)

    def test_late_manifest_mismatch_does_not_partially_import(self):
        self.write_archive([("sample", 1, payload()), ("different", 2, payload("second", 2))])
        with self.assertRaisesRegex(ValueError, "manifest tag"):
            self.restore()
        self.assertEqual(self.db.count_tags(), 0)

    def test_manifest_id_conflict_preserves_existing_record(self):
        self.db.upsert_tag(payload())
        self.write_archive([("sample", 2, {"tag": "sample", "completion_candidates": []})])
        with self.assertRaisesRegex(ValueError, "conflicts"):
            self.restore()
        self.assertEqual(self.db.get_tag("sample")["tag_info"], payload()["tag_info"])

    def test_dry_run_validates_payload_without_opening_database(self):
        self.write_archive([("sample", 1, payload())])
        with patch.object(self.db, "get_tag", side_effect=AssertionError("database opened")), patch.object(
            self.db, "import_tags", side_effect=AssertionError("database written"),
        ):
            self.restore(dry_run=True)
        self.assertFalse(self.db.path.exists())


class NetworkFailureTest(unittest.TestCase):
    def setUp(self):
        self.enterContext(contextlib.redirect_stdout(io.StringIO()))
        self.enterContext(patch.object(view, "log"))
        self.enterContext(patch.object(batch, "log"))

    def test_batch_network_failure_never_disables_tls(self):
        args = SimpleNamespace(no_verify_ssl=False)
        with patch.object(batch, "parse_args", return_value=args), patch.object(
            batch, "create_session",
        ) as create, patch.object(batch, "verify_network", return_value=False):
            with self.assertRaises(SystemExit) as error:
                batch.main()
        self.assertEqual(error.exception.code, 1)
        create.assert_called_once_with(True)
        self.assertFalse(args.no_verify_ssl)

    def test_wiki_network_failure_never_disables_tls(self):
        args = SimpleNamespace(no_verify_ssl=False, limit=0, retries=1, delay=0, workers=1)
        with patch.object(wiki_sync, "parse_args", return_value=args), patch.object(
            wiki_sync, "create_session",
        ) as create, patch.object(wiki_sync, "verify_network", return_value=False):
            self.assertEqual(wiki_sync.main(), 1)
        create.assert_called_once_with(True)
        self.assertFalse(args.no_verify_ssl)

    def test_only_wiki_404_is_missing_and_other_http_errors_abort(self):
        info = payload()["tag_info"]
        for code in (404, 401, 403, 429, 500):
            response = requests.Response()
            response.status_code = code
            error = requests.HTTPError("fixture", response=response)
            with self.subTest(code=code), patch.object(view, "get_json", side_effect=[[info], error, []]):
                if code == 404:
                    self.assertIsNone(view.sync_data("sample", persist_files=False)["wiki"])
                else:
                    with self.assertRaises(requests.HTTPError):
                        view.sync_data("sample", persist_files=False)

    def test_wiki_tag_is_encoded_as_a_single_path_segment(self):
        tag = "?/#"
        info = payload(tag)["tag_info"]
        with patch.object(view, "get_json", side_effect=[[info], {}, []]) as get:
            view.sync_data(tag, persist_files=False)
        self.assertEqual(get.call_args_list[1].args, ("/wiki_pages/%3F%2F%23.json",))

    def test_exhausted_category_rate_limit_raises_instead_of_returning_empty_page(self):
        response = requests.Response()
        response.status_code = 429
        response.headers["Retry-After"] = "invalid"
        session = MagicMock()
        session.get.return_value = response
        with patch.object(view, "request_limiter", contextlib.nullcontext()), patch.object(batch.time, "sleep"):
            with self.assertRaises(requests.HTTPError):
                categories.fetch_page(session, 4, None, max_retries=2)
        self.assertEqual(session.get.call_count, 2)

    def test_list_requests_use_the_current_rate_limiter(self):
        session, limiter = MagicMock(), MagicMock()
        session.get.return_value.status_code = 200
        with patch.object(view, "request_limiter", limiter):
            batch.safe_get(session, "https://example.invalid", max_retries=1)
        limiter.__enter__.assert_called_once()

    def test_expired_success_cache_does_not_bypass_max_age(self):
        ctx = batch.SyncContext(
            args=SimpleNamespace(force=False, max_age=24), metadata={},
            success={"sample"}, failed={}, blocked={}, cursor={},
        )
        with patch.object(batch, "db"), patch.object(view, "check_needs_sync", return_value=True), patch.object(
            view, "sync_data", return_value=payload(),
        ) as sync:
            self.assertEqual(batch.sync_tag(batch.TagRecord("sample", 1), ctx)[0], "synced")
        sync.assert_called_once()

    def test_category_worker_failure_returns_nonzero(self):
        with patch.object(sys, "argv", ["categories", "--categories", "4", "--workers", "1"]), patch.object(
            categories, "create_session",
        ), patch.object(categories, "sync_category", side_effect=requests.ConnectionError("fixture")), patch.object(
            categories, "db",
        ) as database:
            database.count_tags.return_value = 0
            self.assertEqual(categories.main(), 1)

    def test_maintenance_sessions_share_explicit_proxy_and_auth_configuration(self):
        environment = {"DANBOORU_PROXY": "http://127.0.0.1:19090", "DANBOORU_LOGIN": "fixture",
                       "DANBOORU_API_KEY": "fixture-key", "GITHUB_ACTIONS": "true"}
        with patch.dict(batch.os.environ, environment, clear=True):
            for create in (batch.create_session, categories.create_session, wiki_sync.create_session):
                with self.subTest(create=create), create() as session:
                    self.assertTrue(session.verify)
                    self.assertEqual(session.proxies["https"], environment["DANBOORU_PROXY"])
                    self.assertEqual(session.auth, ("fixture", "fixture-key"))


if __name__ == "__main__":
    unittest.main()

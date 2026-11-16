"""Offline import regressions using independent SQLite writers and archives."""

import contextlib
import hashlib
import io
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from unittest.mock import patch
from zipfile import ZipFile

from scripts import build_completion_zip as exporter
from scripts import migrate_json_to_db as migration
from scripts import restore_latest_tag_json as restore
from scripts.tag_db import TagDB


class PublishBeforeImportDB(TagDB):
    """Publish an independent sync at the database batch-write boundary."""

    before_import = None

    def _publish(self):
        callback, self.before_import = self.before_import, None
        if callback is not None:
            callback()

    def upsert_tags_many(self, payloads):
        self._publish()
        return super().upsert_tags_many(payloads)

    def import_tags(self, payloads):
        self._publish()
        return super().import_tags(payloads)


class TagImportIntegrityTest(unittest.TestCase):
    def setUp(self):
        self.root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.db = PublishBeforeImportDB(self.root / "tags.db")
        self.addCleanup(self.db.close)
        self.db.conn
        # Deliberately bypass TagDB's process-local RLock, as another process
        # does. Only an actual SQLite transaction can serialize this writer.
        self.writer = sqlite3.connect(str(self.db.path), timeout=0)
        self.addCleanup(self.writer.close)
        self.cache, self.raw, self.assets = [self.root / name for name in ("cache", "raw", "assets")]
        for directory in (self.cache, self.raw, self.assets):
            directory.mkdir()
        for name, value in (("CACHE_DIR", self.cache), ("DOT_CACHE_DIR", self.raw),
                            ("ASSET_DIR", self.assets), ("db", self.db)):
            self.enterContext(patch.object(migration, name, value))
        self.enterContext(patch.object(restore, "db", self.db))
        self.enterContext(patch.object(sys, "argv", ["migrate_json_to_db"]))
        self.enterContext(contextlib.redirect_stdout(io.StringIO()))

    def source(self, payload):
        path = self.raw / f"{payload['tag']}.json"
        path.write_text(json.dumps(payload), encoding="utf-8")
        return path

    def archive(self, payloads):
        path = self.root / "backup.zip"
        entries = []
        with ZipFile(path, "w") as archive:
            for index, payload in enumerate(payloads):
                raw = json.dumps(payload).encode("utf-8")
                name = f"{index}.json"
                archive.writestr(name, raw)
                entries.append({
                    "tag": payload["tag"], "slug": payload["tag"], "file": name,
                    "sha256": hashlib.sha256(raw).hexdigest(), "size": len(raw),
                })
            archive.writestr("manifest.json", json.dumps({"entries": entries}))
        return path

    def prepare_sync_publication(self):
        self.db.upsert_tag_categories([("sample", 1, 4, 7)])
        self.fresh_candidates = [{"value": "fresh_alias", "insert_value": "sample"}]

        def publish():
            self.writer.execute(
                "UPDATE tags SET completion_candidates=?, completion_authoritative=1, "
                "wiki_other_names=?, aliases=?, updated_at=?, version=version+1 WHERE name='sample'",
                (json.dumps(self.fresh_candidates), json.dumps(["fresh wiki"]),
                 json.dumps(["fresh alias"]), "2026-11-16T06:00:00+00:00"),
            )
            self.writer.commit()

        self.db.before_import = publish

    def assert_fresh_sync_preserved(self):
        stored = self.db.get_tag("sample")
        self.assertEqual(stored["completion_candidates"], self.fresh_candidates)
        self.assertEqual(stored["wiki"], {"other_names": ["fresh wiki"]})
        self.assertEqual(stored["aliases"], ["fresh alias"])
        self.assertEqual(stored["updated_at"], "2026-11-16T06:00:00+00:00")
        self.assertEqual(stored["tag_info"]["post_count"], 50)
        self.assertEqual(self.db.conn.execute(
            "SELECT completion_authoritative FROM tags WHERE name='sample'",
        ).fetchone(), (1,))

    def test_migration_metadata_import_preserves_sync_committed_before_batch_write(self):
        self.prepare_sync_publication()
        self.source({"tag": "sample", "tag_info": {"post_count": 50}})
        self.assertEqual(migration.migrate_tags()[0], 1)
        self.assert_fresh_sync_preserved()

    def test_restore_metadata_import_preserves_sync_committed_before_batch_write(self):
        self.prepare_sync_publication()
        path = self.archive([{"tag": "sample", "tag_info": {"post_count": 50}}])
        restore.restore_archive(path, self.raw, self.assets, dry_run=False)
        self.assert_fresh_sync_preserved()

    def test_invalid_candidate_retains_all_migration_sources_and_records(self):
        good = self.source({"tag": "a_good", "completion_candidates": [{"value": "a_good"}]})
        bad = self.source({"tag": "z_bad", "completion_candidates": [None]})
        originals = {path: path.read_bytes() for path in (good, bad)}
        self.assertEqual(migration.main(), 1)
        self.assertEqual(self.db.count_tags(), 0)
        self.assertEqual({path: path.read_bytes() for path in originals}, originals)

    def test_invalid_candidate_rejects_entire_restore_without_partial_import(self):
        path = self.archive([
            {"tag": "a_good", "completion_candidates": [{"value": "a_good"}]},
            {"tag": "z_bad", "completion_candidates": [None]},
        ])
        with self.assertRaisesRegex(ValueError, "completion_candidates"):
            restore.restore_archive(path, self.raw, self.assets, dry_run=False)
        self.assertEqual(self.db.count_tags(), 0)
        self.assertTrue(path.is_file())

    def test_dry_run_rejects_invalid_candidates_without_database_access(self):
        path = self.archive([{"tag": "sample", "completion_candidates": [None]}])
        with patch.object(restore, "db") as database:
            with self.assertRaisesRegex(ValueError, "completion_candidates"):
                restore.restore_archive(path, self.raw, self.assets, dry_run=True)
        self.assertFalse(database.mock_calls)

    def test_import_fences_independent_sqlite_writer_before_reading_current_rows(self):
        self.db.upsert_tag_categories([("sample", 1, 4, 7)])
        read_current = self.db.get_tag
        blocked = []

        def read_under_write_fence(tag):
            try:
                with self.assertRaisesRegex(sqlite3.OperationalError, "locked"):
                    self.writer.execute("UPDATE tags SET category=0 WHERE name='sample'")
                blocked.append(tag)
            finally:
                self.writer.rollback()
            return read_current(tag)

        with patch.object(self.db, "get_tag", side_effect=read_under_write_fence):
            self.db.import_tags([{"tag": "sample", "tag_info": {"post_count": 50}}])
        self.assertEqual(blocked, ["sample"])
        self.assertFalse(self.db.conn.in_transaction)
        self.writer.execute("UPDATE tags SET category=0 WHERE name='sample'")
        self.writer.commit()
        self.assertEqual(self.db.get_tag("sample")["tag_info"]["category"], 0)

    def test_late_sqlite_failure_rolls_back_all_rows_and_allows_retry(self):
        self.db.upsert_tag({
            "tag": "a_existing", "completion_candidates": [{"value": "old"}],
            "wiki": {"other_names": ["original metadata"]},
        })
        before = self.writer.execute("SELECT * FROM tags ORDER BY name").fetchall()
        self.db.conn.execute(
            "CREATE TRIGGER reject_import BEFORE INSERT ON tags WHEN NEW.name='z_new' "
            "BEGIN SELECT RAISE(FAIL, 'fixture write failure'); END",
        )
        payloads = [
            {"tag": "a_existing", "completion_candidates": [{"value": "changed"}]},
            {"tag": "z_new", "completion_candidates": []},
        ]
        with self.assertRaisesRegex(sqlite3.IntegrityError, "fixture write failure"):
            self.db.import_tags(payloads)
        self.assertEqual(self.writer.execute("SELECT * FROM tags ORDER BY name").fetchall(), before)
        self.assertFalse(self.db.conn.in_transaction)
        self.db.conn.execute("DROP TRIGGER reject_import")
        self.db.import_tags(payloads)
        self.assertEqual(self.db.get_tag("a_existing")["completion_candidates"], [{"value": "changed"}])
        self.assertEqual(self.db.get_tag("z_new")["completion_candidates"], [])

    def test_stored_identity_conflict_rolls_back_earlier_archive_rows(self):
        self.db.upsert_tag({"tag": "z_existing", "tag_info": {"id": 1}, "completion_candidates": []})
        before = self.writer.execute("SELECT * FROM tags ORDER BY name").fetchall()
        path = self.archive([
            {"tag": "a_new", "completion_candidates": [{"value": "a_new"}]},
            {"tag": "z_existing", "tag_info": {"id": 2}, "completion_candidates": []},
        ])
        with self.assertRaisesRegex(ValueError, "conflicts with the stored tag"):
            restore.restore_archive(path, self.raw, self.assets, dry_run=False)
        self.assertEqual(self.writer.execute("SELECT * FROM tags ORDER BY name").fetchall(), before)
        self.assertFalse(self.db.conn.in_transaction)

    def test_each_invalid_candidate_shape_rolls_back_the_entire_import(self):
        invalid_items = [
            None, [], "sample", {}, {"value": None}, {"value": 1}, {"value": ""},
            {"value": "sample", "insert_value": None},
            {"value": "sample", "insert_value": []},
            {"value": "sample", "insert_value": ""},
        ]
        for candidate in invalid_items:
            with self.subTest(candidate=candidate):
                with self.assertRaisesRegex(ValueError, "completion_candidates"):
                    self.db.import_tags([
                        {"tag": "a_good", "completion_candidates": [{"value": "a_good"}]},
                        {"tag": "z_bad", "completion_candidates": [{"value": "valid"}, candidate]},
                    ])
                self.assertEqual(self.writer.execute("SELECT COUNT(*) FROM tags").fetchone(), (0,))
                self.assertFalse(self.db.conn.in_transaction)

    def test_valid_candidate_defaults_and_optional_export_fallbacks_are_preserved(self):
        candidates = [
            {"value": "alias", "source": 7, "score": "invalid optional score"},
            {"value": "alias2", "insert_value": "sample", "source": "wiki", "score": 9},
        ]
        self.source({"tag": "sample", "completion_candidates": candidates})
        migration.migrate_tags()
        self.assertEqual(self.db.get_tag("sample")["completion_candidates"], candidates)
        with patch.object(exporter, "TAG_DB", self.db.path):
            self.assertCountEqual(exporter.load_candidates_from_db(), [
                ("alias", "alias", "", 0, None),
                ("alias2", "sample", "wiki", 9, None),
            ])
        self.assertEqual(self.db.conn.execute(
            "SELECT completion_authoritative FROM tags WHERE name='sample'",
        ).fetchone(), (1,))

    def test_valid_empty_group_remains_authoritative_and_can_clean_its_source(self):
        self.db.upsert_tag({"tag": "sample", "completion_candidates": [{"value": "old"}]})
        source = self.source({"tag": "sample", "completion_candidates": []})
        self.assertEqual(migration.main(), 0)
        self.assertFalse(source.exists())
        self.assertEqual(self.db.get_tag("sample")["completion_candidates"], [])
        self.assertEqual(self.db.conn.execute(
            "SELECT completion_authoritative FROM tags WHERE name='sample'",
        ).fetchone(), (1,))


if __name__ == "__main__":
    unittest.main()

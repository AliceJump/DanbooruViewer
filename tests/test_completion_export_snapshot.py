"""Real SQLite WAL regressions for consistent completion export inputs."""

import contextlib
import io
import json
from pathlib import Path
import sqlite3
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from zipfile import ZipFile

from scripts import build_completion_zip as exporter


class CompletionExportSnapshotTest(unittest.TestCase):
    def setUp(self):
        self.root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.crawler = self.root / "crawler.db"
        self.seed = self.root / "seed.db"
        self.output = self.root / "completion.zip"
        self.manifest = self.root / "completion.manifest.json"
        for name, path in (
            ("TAG_DB", self.crawler), ("SEED_DB", self.seed),
            ("OUTPUT_FILE", self.output), ("MANIFEST_FILE", self.manifest),
            ("TEMP_OUTPUT_FILE", self.root / "completion.zip.tmp"),
            ("INDEX_FILE", self.root / "index.zip"),
            ("BOOTSTRAP_FILE", self.root / "bootstrap.json"),
        ):
            self.enterContext(patch.object(exporter, name, path))
        self.enterContext(contextlib.redirect_stdout(io.StringIO()))
        self.enterContext(patch.object(exporter, "parse_args", return_value=SimpleNamespace(
            store=True, best=False, compresslevel=3, force=False, clean_legacy=False,
        )))
        self.writer = sqlite3.connect(self.crawler, timeout=0.1)
        self.addCleanup(self.writer.close)
        self.writer.execute("PRAGMA journal_mode=WAL")
        self.writer.executescript("""
            CREATE TABLE tags (
                name TEXT PRIMARY KEY, category INTEGER,
                completion_candidates TEXT, completion_authoritative INTEGER
            );
            CREATE TABLE sync_status (tag TEXT PRIMARY KEY, status TEXT, last_sync_time TEXT);
            INSERT INTO tags VALUES ('sample', 4, '[]', 0);
        """)

    def set_candidate(self, value, category=4):
        self.writer.execute(
            "UPDATE tags SET completion_candidates=?, category=?, completion_authoritative=1 "
            "WHERE name='sample'",
            (json.dumps([{"value": value, "insert_value": "sample", "score": 100}]), category),
        )
        # A genuine second-connection WAL commit must remain possible while
        # the export's read transaction is open.
        self.writer.commit()

    def legacy(self):
        with ZipFile(self.output, "w") as archive:
            archive.writestr(exporter.COMPACT_FILE, json.dumps([
                {"v": "legacy_alias", "i": "sample", "r": 85, "c": 4},
            ]))

    def compact(self):
        with ZipFile(self.output) as archive:
            return json.loads(archive.read(exporter.COMPACT_FILE))

    def test_placeholder_authority_cannot_change_after_candidate_read(self):
        self.legacy()
        read_candidates = exporter.load_candidates_from_db
        calls = []

        def commit_after_candidates(*args, **kwargs):
            result = read_candidates(*args, **kwargs)
            self.set_candidate("new_alias", category=3)
            calls.append(True)
            return result

        with patch.object(exporter, "load_candidates_from_db", side_effect=commit_after_candidates):
            result = exporter.build_suggestions()
        self.assertEqual(calls, [True])
        self.assertEqual(set(result), {("legacy_alias", "sample")})
        self.assertEqual(result[("legacy_alias", "sample")][4], 4)
        self.assertEqual(set(exporter.build_suggestions()), {("new_alias", "sample")})

    def test_category_cannot_change_after_candidate_read(self):
        self.set_candidate("old_alias")
        read_candidates = exporter.load_candidates_from_db

        def commit_after_candidates(*args, **kwargs):
            result = read_candidates(*args, **kwargs)
            self.set_candidate("new_alias", category=3)
            return result

        with patch.object(exporter, "load_candidates_from_db", side_effect=commit_after_candidates):
            result = exporter.build_suggestions()
        self.assertEqual(set(result), {("old_alias", "sample")})
        self.assertEqual(result[("old_alias", "sample")][4], 4)

    def test_manifest_and_candidates_share_snapshot_then_next_run_rebuilds(self):
        self.set_candidate("old_alias")
        fingerprint = exporter.db_fingerprint

        def commit_after_fingerprint(*args, **kwargs):
            signature = fingerprint(*args, **kwargs)
            self.set_candidate("new_alias", category=3)
            return signature

        with patch.object(exporter, "db_fingerprint", side_effect=commit_after_fingerprint):
            exporter.main()
        self.assertEqual([(item["v"], item["c"]) for item in self.compact()], [("old_alias", 4)])
        self.assertNotEqual(
            json.loads(self.manifest.read_text())["signature"]["crawler_sha256"],
            exporter.db_fingerprint()["crawler_sha256"],
        )
        exporter.main()
        self.assertEqual([(item["v"], item["c"]) for item in self.compact()], [("new_alias", 3)])
        with patch.object(exporter, "build_suggestions", side_effect=AssertionError("unexpected rebuild")):
            exporter.main()

    def test_transient_update_cannot_publish_wrong_data_under_unchanged_signature(self):
        self.set_candidate("old_alias")
        fingerprint = exporter.db_fingerprint
        read_candidates = exporter.load_candidates_from_db

        def temporary_update(*args, **kwargs):
            signature = fingerprint(*args, **kwargs)
            self.set_candidate("transient_alias")
            return signature

        def restore_after_candidates(*args, **kwargs):
            result = read_candidates(*args, **kwargs)
            self.set_candidate("old_alias")
            return result

        with patch.object(exporter, "db_fingerprint", side_effect=temporary_update), patch.object(
            exporter, "load_candidates_from_db", side_effect=restore_after_candidates,
        ):
            exporter.main()
        with patch.object(exporter, "build_suggestions", side_effect=AssertionError("unexpected rebuild")):
            exporter.main()
        self.assertEqual([item["v"] for item in self.compact()], ["old_alias"])

    def seed_writer(self, *, category=True):
        connection = sqlite3.connect(self.seed, timeout=0.1)
        self.addCleanup(connection.close)
        connection.execute("PRAGMA journal_mode=WAL")
        connection.execute(
            "CREATE TABLE completion_candidates (value TEXT, insert_value TEXT, source TEXT, score INTEGER"
            + (", category INTEGER" if category else "") + ")"
        )
        connection.execute(
            "INSERT INTO completion_candidates VALUES ('old_seed', 'seed_tag', 'tag', 90"
            + (", 2" if category else "") + ")"
        )
        connection.commit()
        return connection

    def test_seed_wal_fingerprint_describes_the_rows_used_for_suggestions(self):
        seed_writer = self.seed_writer()
        fingerprint = exporter.db_fingerprint

        def commit_after_fingerprint(*args, **kwargs):
            signature = fingerprint(*args, **kwargs)
            seed_writer.execute("UPDATE completion_candidates SET value='new_seed', category=3")
            seed_writer.commit()
            return signature

        with patch.object(exporter, "db_fingerprint", side_effect=commit_after_fingerprint):
            exporter.main()
        self.assertEqual([(item["v"], item["c"]) for item in self.compact()], [("old_seed", 2)])
        exporter.main()
        self.assertEqual([(item["v"], item["c"]) for item in self.compact()], [("new_seed", 3)])
        signature = exporter.db_fingerprint()
        seed_writer.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        self.assertEqual(exporter.db_fingerprint(), signature)
        with patch.object(exporter, "build_suggestions", side_effect=AssertionError("unexpected rebuild")):
            exporter.main()

    def test_old_schemas_export_without_migration_or_writable_connections(self):
        self.writer.execute("ALTER TABLE tags DROP COLUMN completion_authoritative")
        self.writer.execute("INSERT INTO sync_status VALUES ('sample', 'success', NULL)")
        self.writer.commit()
        seed_writer = self.seed_writer(category=False)
        self.legacy()
        before = {path: path.read_bytes() for path in (self.crawler, self.seed)}
        connect = sqlite3.connect
        connections = []

        def readonly_connect(database, *args, **kwargs):
            self.assertTrue(kwargs.get("uri"))
            self.assertIn("mode=ro", str(database))
            connection = connect(database, *args, **kwargs)
            connections.append(connection)
            return connection

        with patch.object(exporter.sqlite3, "connect", side_effect=readonly_connect):
            result = exporter.build_suggestions()
            exporter.db_fingerprint()
            exporter.main()
        self.assertEqual(set(result), {("old_seed", "seed_tag")})
        self.assertIsNone(result[("old_seed", "seed_tag")][4])
        self.assertEqual({path: path.read_bytes() for path in before}, before)
        self.assertNotIn("completion_authoritative", {
            row[1] for row in self.writer.execute("PRAGMA table_info(tags)")
        })
        self.assertNotIn("category", {
            row[1] for row in seed_writer.execute("PRAGMA table_info(completion_candidates)")
        })
        for connection in connections:
            with self.assertRaises(sqlite3.ProgrammingError):
                connection.execute("SELECT 1")


if __name__ == "__main__":
    unittest.main()

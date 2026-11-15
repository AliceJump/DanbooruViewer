"""Contract and build-pipeline tests for the precomputed mobile tag index."""

import hashlib
import json
from pathlib import Path
import struct
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from zipfile import ZipFile

from scripts import build_completion_index as indexer
from scripts import build_completion_zip as exporter


def decode_index(binary):
    """Independent format reader used to check the cross-language wire contract."""
    magic, count, search_size, original_size, source_size = struct.unpack_from(
        "<8sIIII", binary
    )
    if magic != b"DBTAGI01":
        raise ValueError("wrong magic")
    records_start = 24
    value_ids_start = records_start + count * 28
    insert_ids_start = value_ids_start + count * 4
    search_start = insert_ids_start + count * 4
    original_start = search_start + search_size
    source_start = original_start + original_size
    if source_start + source_size != len(binary):
        raise ValueError("incorrect section sizes")
    sources = json.loads(binary[source_start:])

    def string_at(start):
        return binary[start:binary.index(b"\0", start)].decode("utf-8")

    decoded = []
    raw_records = []
    for row_id in range(count):
        row = struct.unpack_from("<IIIIiiI", binary, records_start + row_id * 28)
        offset, delta, value_original, insert_original, score, category, source = row
        raw_records.append(row)
        value_lower = string_at(search_start + offset)
        insert_lower = string_at(search_start + offset + delta)
        value = (
            value_lower if value_original == 0xFFFFFFFF
            else string_at(original_start + value_original)
        )
        insert = (
            insert_lower if insert_original == 0xFFFFFFFF
            else string_at(original_start + insert_original)
        )
        decoded.append({
            "value": value,
            "insert": insert,
            "value_lower": value_lower,
            "insert_lower": insert_lower,
            "score": score,
            "category": None if category == -1 else category,
            "source": sources[source],
        })
    return {
        "rows": decoded,
        "records": raw_records,
        "value_ids": list(struct.unpack_from(f"<{count}I", binary, value_ids_start)),
        "insert_ids": list(struct.unpack_from(f"<{count}I", binary, insert_ids_start)),
        "search": binary[search_start:original_start],
        "original": binary[original_start:source_start],
        "sources": sources,
    }


class CompletionIndexFormatTest(unittest.TestCase):
    def test_original_spelling_aliases_sources_and_category_zero_round_trip(self):
        candidates = indexer.normalize_candidates([
            ("Hatsune_Miku", "Hatsune_Miku", "tag", 100, 4),
            ("初音未来", "Hatsune_Miku", "wiki_other_name", 90, 4),
            ("初音ミク", "Hatsune_Miku", "wiki_other_name", 89, 4),
            ("blue_eyes", "blue_eyes", "tag", 100, 0),
            ("Miku", "Hatsune_Miku", "alias", 85, 4),
            ("unknown", "unknown", "", -2, None),
        ])
        decoded = decode_index(indexer.pack_index(candidates))
        actual = [
            (row["value"], row["insert"], row["source"], row["score"], row["category"])
            for row in decoded["rows"]
        ]
        self.assertEqual(actual, candidates)
        self.assertEqual(decoded["rows"][1]["category"], 0)
        self.assertIsNone(decoded["rows"][-1]["category"])

        # One stored lowercase/original string serves both equal fields.
        self.assertEqual(decoded["records"][0][1], 0)
        self.assertEqual(decoded["records"][0][2], decoded["records"][0][3])
        self.assertEqual(decoded["original"].count(b"Hatsune_Miku\0"), 1)
        self.assertEqual(decoded["records"][1][2:4], (0xFFFFFFFF, 0xFFFFFFFF))

        # The insert-sorted range preserves every alias for sparse metadata
        # lookup, including the first non-ASCII display name and category.
        aliases = [
            decoded["rows"][row_id]
            for row_id in decoded["insert_ids"]
            if decoded["rows"][row_id]["insert_lower"] == "hatsune_miku"
        ]
        self.assertEqual(len(aliases), 4)
        display = next(row["value"] for row in aliases if not row["value"].isascii())
        self.assertEqual(display, "初音未来")
        self.assertEqual(aliases[0]["category"], 4)

    def test_sort_tables_use_lowercase_utf8_bytes_then_record_id(self):
        candidates = indexer.normalize_candidates([
            ("B", "TARGET", "tag", 100, None),
            ("a", "target", "alias", 85, None),
            ("😀", "Target", "wiki_other_name", 90, None),
            ("中", "other", "tag", 100, 0),
            ("z", "a", "tag", 100, None),
        ])
        decoded = decode_index(indexer.pack_index(candidates))
        rows = decoded["rows"]
        self.assertEqual(decoded["value_ids"], [4, 0, 1, 2, 3])
        self.assertEqual(
            [rows[row_id]["value_lower"] for row_id in decoded["value_ids"]],
            ["a", "b", "z", "中", "😀"],
        )
        target_ids = [
            row_id for row_id in decoded["insert_ids"]
            if rows[row_id]["insert_lower"] == "target"
        ]
        self.assertEqual(target_ids, sorted(target_ids))
        self.assertEqual(sorted(decoded["value_ids"]), list(range(len(rows))))
        self.assertEqual(sorted(decoded["insert_ids"]), list(range(len(rows))))

    def test_lowercase_matches_dart_simple_unicode_mapping(self):
        cases = {
            "ASCII_TAG": "ascii_tag",
            "中文": "中文",
            "İ": "i",
            "ΟΣ": "οσ",
            "Σ": "σ",
            "ẞ": "ß",
            "𐐀": "𐐨",
        }
        for original, expected in cases.items():
            with self.subTest(original=original):
                self.assertEqual(indexer.dart_lower(original), expected)
                decoded = decode_index(indexer.pack_index([
                    indexer.Candidate(original, original, "tag", 100, None),
                ]))
                self.assertEqual(decoded["rows"][0]["value_lower"], expected)
                self.assertEqual(decoded["rows"][0]["value"], original)

    def test_dedup_uses_pair_keeps_best_score_and_does_not_drop_aliases(self):
        actual = indexer.normalize_candidates([
            ("TAG", "tag", "first", 20, None),
            ("tag", "TAG", "better", 100, 0),
            ("Tag", "Tag", "equal_score_later", 100, 4),
            ("别名", "tag", "wiki_other_name", 90, 0),
            ("tag", "different", "alias", 85, None),
            ("", "empty", "tag", 100, None),
            ("spaces", "  ", "tag", 100, None),
        ])
        self.assertEqual(actual, [
            ("tag", "TAG", "better", 100, 0),
            ("别名", "tag", "wiki_other_name", 90, 0),
            ("tag", "different", "alias", 85, None),
        ])

    def test_empty_index_has_valid_sections(self):
        binary = indexer.pack_index([])
        self.assertEqual(len(binary), 26)
        decoded = decode_index(binary)
        self.assertEqual(decoded["rows"], [])
        self.assertEqual(decoded["value_ids"], [])
        self.assertEqual(decoded["sources"], [])

    def test_rejects_unrepresentable_strings_and_numbers(self):
        for candidate in [
            ("bad\0tag", "tag", "tag", 100, None),
            ("tag", "bad\0tag", "tag", 100, None),
            ("tag", "tag", "tag", 1 << 31, None),
            ("tag", "tag", "tag", 100, -1),
        ]:
            with self.subTest(candidate=candidate):
                with self.assertRaises(ValueError):
                    indexer.pack_index([candidate])


class CompletionIndexBuildTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "completion.zip"
        self.index = self.root / "index.zip"
        self.bootstrap = self.root / "bootstrap.json"

    def write_source(self, items):
        with ZipFile(self.source, "w") as archive:
            archive.writestr("completion_candidates.json", json.dumps(items))

    def test_build_from_existing_zip_without_a_database(self):
        items = [
            {"v": f"tag_{index:02d}", "i": f"tag_{index:02d}", "s": "tag", "r": 100, "c": 0}
            for index in range(14)
        ] + [{"v": "中文别名", "i": "tag_00", "s": "wiki_other_name", "r": 90, "c": 0}]
        self.write_source(items)
        result = indexer.build_index(self.source, self.index, self.bootstrap)
        with ZipFile(self.index) as archive:
            self.assertEqual(archive.namelist(), ["completion_index.bin"])
            binary = archive.read("completion_index.bin")
        self.assertEqual(result["version"], 1)
        self.assertEqual(result["count"], 15)
        self.assertEqual(result["suggestions"], items[:10])
        self.assertEqual(result["sourceSha256"], indexer.file_sha256(self.source))
        self.assertEqual(result["indexSha256"], hashlib.sha256(binary).hexdigest())
        self.assertEqual(result["archiveSha256"], indexer.file_sha256(self.index))
        self.assertEqual(len(decode_index(binary)["rows"]), 15)
        self.assertTrue(indexer.outputs_are_current(self.source, self.index, self.bootstrap))
        with patch.object(indexer, "load_candidates_from_zip", side_effect=AssertionError("unexpected reload")):
            self.assertEqual(indexer.build_index(self.source, self.index, self.bootstrap), result)

    def test_source_format_version_and_missing_or_corrupt_output_force_rebuild(self):
        self.write_source([{"v": "tag", "r": 100}])
        original = indexer.build_index(self.source, self.index, self.bootstrap)
        self.index.write_bytes(b"truncated")
        self.assertFalse(indexer.outputs_are_current(self.source, self.index, self.bootstrap))
        repaired = indexer.build_index(self.source, self.index, self.bootstrap)
        self.assertEqual(repaired, original)

        metadata = json.loads(self.bootstrap.read_text())
        metadata["version"] = 0
        self.bootstrap.write_text(json.dumps(metadata))
        self.assertFalse(indexer.outputs_are_current(self.source, self.index, self.bootstrap))
        indexer.build_index(self.source, self.index, self.bootstrap)

        self.index.unlink()
        self.assertFalse(indexer.outputs_are_current(self.source, self.index, self.bootstrap))
        indexer.build_index(self.source, self.index, self.bootstrap)
        self.write_source([{"v": "new_tag", "r": 100}])
        self.assertFalse(indexer.outputs_are_current(self.source, self.index, self.bootstrap))
        updated = indexer.build_index(self.source, self.index, self.bootstrap)
        self.assertEqual(updated["suggestions"][0]["v"], "new_tag")
        self.assertNotEqual(updated["sourceSha256"], original["sourceSha256"])

    def test_missing_or_wrong_uncompressed_digest_forces_rebuild(self):
        self.write_source([{"v": "tag", "r": 100}])
        original = indexer.build_index(self.source, self.index, self.bootstrap)
        for expected_digest in (None, "0" * 64):
            with self.subTest(index_sha=expected_digest):
                metadata = dict(original)
                if expected_digest is None:
                    metadata.pop("indexSha256")
                else:
                    metadata["indexSha256"] = expected_digest
                self.bootstrap.write_text(json.dumps(metadata))
                self.assertFalse(indexer.outputs_are_current(self.source, self.index, self.bootstrap))
                repaired = indexer.build_index(self.source, self.index, self.bootstrap)
                self.assertEqual(repaired, original)
                self.assertTrue(indexer.outputs_are_current(self.source, self.index, self.bootstrap))

    def test_manifest_count_must_match_binary_header_before_skipping(self):
        self.write_source([{"v": f"tag_{index}", "r": 100} for index in range(12)])
        original = indexer.build_index(self.source, self.index, self.bootstrap)
        metadata = dict(original)
        # Both counts still require exactly ten bootstrap entries, so the
        # disagreement can only be discovered by reading the binary header.
        metadata["count"] += 1
        self.bootstrap.write_text(json.dumps(metadata))
        self.assertFalse(indexer.outputs_are_current(self.source, self.index, self.bootstrap))
        self.assertEqual(
            indexer.build_index(self.source, self.index, self.bootstrap), original,
        )

    def test_invalid_binary_header_or_length_forces_rebuild_even_with_matching_hashes(self):
        self.write_source([{"v": "tag", "r": 100}])
        original = indexer.build_index(self.source, self.index, self.bootstrap)
        with ZipFile(self.index) as archive:
            binary = archive.read("completion_index.bin")
        wrong_count = bytearray(binary)
        struct.pack_into("<I", wrong_count, 8, original["count"] + 1)
        wrong_length = bytearray(binary)
        search_size = struct.unpack_from("<I", wrong_length, 12)[0]
        struct.pack_into("<I", wrong_length, 12, search_size + 1)
        variants = {
            "magic": b"DBTAGI99" + binary[8:],
            "short_header": binary[:12],
            "record_count": wrong_count,
            "section_length": wrong_length,
            "truncated_body": binary[:-1],
            "trailing_body": binary + b"\0",
        }
        for name, invalid_binary in variants.items():
            with self.subTest(invalid_binary=name):
                with ZipFile(self.index, "w") as archive:
                    archive.writestr("completion_index.bin", invalid_binary)
                metadata = dict(original)
                metadata["archiveSha256"] = indexer.file_sha256(self.index)
                metadata["indexSha256"] = hashlib.sha256(invalid_binary).hexdigest()
                self.bootstrap.write_text(json.dumps(metadata))
                self.assertFalse(indexer.outputs_are_current(self.source, self.index, self.bootstrap))
                repaired = indexer.build_index(self.source, self.index, self.bootstrap)
                self.assertEqual(repaired, original)
                self.assertTrue(indexer.outputs_are_current(self.source, self.index, self.bootstrap))

    def test_per_tag_legacy_payload_and_category_zero_are_supported(self):
        with ZipFile(self.source, "w") as archive:
            archive.writestr("tag.json", json.dumps({"completion_candidates": [
                {"value": "标签", "insert_value": "tag", "source": "wiki_other_name", "score": 90, "category": 0},
                {"value": "tag", "insert_value": "tag", "source": "tag", "score": 100},
            ]}))
        self.assertEqual(indexer.load_candidates_from_zip(self.source), [
            ("tag", "tag", "tag", 100, None),
            ("标签", "tag", "wiki_other_name", 90, 0),
        ])

    def test_lfs_pointer_fails_with_actionable_message(self):
        self.source.write_text("version https://git-lfs.github.com/spec/v1\n")
        with self.assertRaisesRegex(ValueError, "Git LFS"):
            indexer.build_index(self.source, self.index, self.bootstrap)
        self.assertFalse(self.index.exists())
        self.assertFalse(self.bootstrap.exists())

    def test_write_failure_preserves_existing_asset_and_removes_temporaries(self):
        self.write_source([{"v": "tag", "r": 100}])
        indexer.build_index(self.source, self.index, self.bootstrap)
        previous = self.index.read_bytes(), self.bootstrap.read_bytes()
        with patch.object(indexer.os, "replace", side_effect=OSError("disk failure")):
            with self.assertRaisesRegex(OSError, "disk failure"):
                indexer.build_index(self.source, self.index, self.bootstrap, force=True)
        self.assertEqual((self.index.read_bytes(), self.bootstrap.read_bytes()), previous)
        self.assertEqual(list(self.root.glob("*.tmp")), [])

    def test_unchanged_legacy_export_still_creates_missing_index(self):
        self.write_source([{"v": "tag", "r": 100, "c": 0}])
        manifest = self.root / "completion.manifest.json"
        signature = {"test": "unchanged"}
        manifest.write_text(json.dumps({
            "signature": signature,
            "items": 1,
            "output_size": self.source.stat().st_size,
        }))
        args = SimpleNamespace(store=False, best=False, compresslevel=3, force=False, clean_legacy=False)
        with patch.object(exporter, "OUTPUT_FILE", self.source), patch.object(
            exporter, "INDEX_FILE", self.index,
        ), patch.object(exporter, "BOOTSTRAP_FILE", self.bootstrap), patch.object(
            exporter, "MANIFEST_FILE", manifest,
        ), patch.object(exporter, "db_fingerprint", return_value=signature), patch.object(
            exporter, "parse_args", return_value=args,
        ), patch.object(exporter, "build_suggestions", side_effect=AssertionError("unexpected DB reload")):
            exporter.main()
        self.assertTrue(indexer.outputs_are_current(self.source, self.index, self.bootstrap))
        self.assertEqual(json.loads(manifest.read_text())["index_version"], 1)


if __name__ == "__main__":
    unittest.main()

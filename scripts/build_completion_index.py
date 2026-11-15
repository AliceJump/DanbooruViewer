#!/usr/bin/env python3
"""Prebuild the compact, read-only tag search index shipped by the app.

The crawler database and the legacy JSON ZIP remain build inputs. The app only
needs the binary ZIP and its small bootstrap JSON; it does not parse millions of
JSON objects or build sorting tables at launch.

Binary v1 (all numbers little-endian):
  DBTAGI01, record count, search bytes, original bytes, sources JSON bytes
  28-byte records, value-sorted uint32 IDs, insert-sorted uint32 IDs,
  NUL-terminated lower-case UTF-8 strings, optional original strings, sources JSON.
"""

from __future__ import annotations

import argparse
from array import array
import hashlib
import json
import os
from pathlib import Path
import struct
import sys
import tempfile
from typing import Iterable, NamedTuple, Sequence
from zipfile import BadZipFile, ZIP_DEFLATED, ZipFile, ZipInfo
import zlib

if __package__:
    from .completion_normalization import normalize_completion_key as dart_lower
else:
    from completion_normalization import normalize_completion_key as dart_lower


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SOURCE = ROOT / "assets" / "danbooru_completion.zip"
DEFAULT_INDEX = ROOT / "assets" / "danbooru_completion.index.zip"
DEFAULT_BOOTSTRAP = ROOT / "assets" / "danbooru_completion.bootstrap.json"
FORMAT_VERSION = 1
MAGIC = b"DBTAGI01"
INDEX_MEMBER = "completion_index.bin"
HEADER = struct.Struct("<8sIIII")
RECORD = struct.Struct("<IIIIiiI")
UINT32_MAX = 0xFFFFFFFF
INT32_MIN = -(1 << 31)
INT32_MAX = (1 << 31) - 1


class Candidate(NamedTuple):
    value: str
    insert_value: str
    source: str
    score: int
    category: int | None


def _is_int(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _validate_text(value: str) -> None:
    if "\0" in value:
        raise ValueError("completion strings cannot contain NUL characters")
    # Fail at build time instead of shipping an undecodable string table.
    value.encode("utf-8")


def normalize_candidates(records: Iterable[Candidate | tuple]) -> list[Candidate]:
    """Keep the highest score per lower-case (display, insert) pair.

    Preserve spelling, aliases, category zero, and source. Equal-score duplicates
    retain the first occurrence, as in the legacy exporter/runtime loader.
    """
    unique: dict[tuple[str, str], Candidate] = {}
    for record in records:
        value, insert_value, source, score, category = record
        if not isinstance(value, str) or not isinstance(insert_value, str):
            continue
        if not value.strip() or not insert_value.strip():
            continue
        source = source if isinstance(source, str) else ""
        score = score if _is_int(score) else 0
        category = category if _is_int(category) else None
        if not INT32_MIN <= score <= INT32_MAX:
            raise ValueError("completion score does not fit a signed 32-bit field")
        if category is not None and not 0 <= category <= INT32_MAX:
            raise ValueError("completion category must be a non-negative 32-bit integer")
        for text in (value, insert_value, source):
            _validate_text(text)
        key = (dart_lower(value), dart_lower(insert_value))
        candidate = Candidate(value, insert_value, source, score, category)
        previous = unique.get(key)
        if previous is None or score > previous.score:
            unique[key] = candidate
    return sorted(unique.values(), key=lambda item: (-item.score, item.value))


def _candidate_from_json(item: dict) -> Candidate:
    value = item.get("value", item.get("v", ""))
    insert_value = item.get("insert_value", item.get("i", value))
    return Candidate(
        value,
        insert_value,
        item.get("source", item.get("s", "")),
        item.get("score", item.get("r", 0)),
        item.get("category", item.get("c")),
    )


def load_candidates_from_zip(source: Path) -> list[Candidate]:
    """Read compact or per-tag legacy JSON ZIPs without requiring crawler data."""
    source = Path(source)

    def records():
        try:
            with ZipFile(source) as archive:
                names = sorted(
                    name for name in archive.namelist()
                    if name.endswith(".json") and not name.endswith("/")
                )
                if not names:
                    raise ValueError("completion ZIP contains no JSON records")
                for name in names:
                    payload = json.loads(archive.read(name))
                    items = (
                        payload if isinstance(payload, list)
                        else payload.get("completion_candidates", [])
                        if isinstance(payload, dict) else []
                    )
                    if not isinstance(items, list):
                        raise ValueError(f"invalid completion candidate list in {name}")
                    for item in items:
                        if isinstance(item, dict):
                            yield _candidate_from_json(item)
        except BadZipFile as exc:
            raise ValueError(
                f"{source} is not a ZIP; fetch its Git LFS content before building"
            ) from exc

    return normalize_candidates(records())


def _u32(value: int, description: str) -> int:
    if not 0 <= value < UINT32_MAX:
        raise ValueError(f"{description} exceeds the binary index size limit")
    return value


def _uint32_bytes(values: Iterable[int]) -> bytes:
    packed = array("I", values)
    if packed.itemsize != 4:
        raise RuntimeError("this builder requires 32-bit unsigned array integers")
    if sys.byteorder != "little":
        packed.byteswap()
    return packed.tobytes()


def pack_index(candidates: Sequence[Candidate | tuple]) -> bytes:
    """Pack already normalized, rank-ordered candidates into binary format v1."""
    count = _u32(len(candidates), "record count")
    records = bytearray(count * RECORD.size)
    search_blob = bytearray()
    original_blob = bytearray()
    original_offsets: dict[str, int] = {}
    sources: list[str] = []
    source_ids: dict[str, int] = {}
    value_keys: list[bytes] = []
    insert_keys: list[bytes] = []

    def original_offset(original: str, lower: str) -> int:
        if original == lower:
            return UINT32_MAX
        offset = original_offsets.get(original)
        if offset is None:
            offset = _u32(len(original_blob), "original string offset")
            original_offsets[original] = offset
            original_blob.extend(original.encode("utf-8"))
            original_blob.append(0)
        return offset

    for row_id, item in enumerate(candidates):
        value, insert_value, source, score, category = item
        for text in (value, insert_value, source):
            _validate_text(text)
        if not _is_int(score) or not INT32_MIN <= score <= INT32_MAX:
            raise ValueError("completion score does not fit a signed 32-bit field")
        if category is not None and (
            not _is_int(category) or not 0 <= category <= INT32_MAX
        ):
            raise ValueError("invalid completion category")
        value_lower = dart_lower(value)
        insert_lower = dart_lower(insert_value)
        value_bytes = value_lower.encode("utf-8")
        insert_bytes = value_bytes if insert_lower == value_lower else insert_lower.encode("utf-8")
        value_keys.append(value_bytes)
        insert_keys.append(insert_bytes)
        search_start = _u32(len(search_blob), "search string offset")
        search_blob.extend(value_bytes)
        search_blob.append(0)
        insert_delta = 0
        if insert_lower != value_lower:
            insert_delta = _u32(len(value_bytes) + 1, "insert delta")
            search_blob.extend(insert_bytes)
            search_blob.append(0)
        if source not in source_ids:
            source_ids[source] = len(sources)
            sources.append(source)
        RECORD.pack_into(
            records,
            row_id * RECORD.size,
            search_start,
            insert_delta,
            original_offset(value, value_lower),
            original_offset(insert_value, insert_lower),
            score,
            -1 if category is None else category,
            source_ids[source],
        )

    # sorted() is stable, so equal byte strings retain ascending record IDs.
    by_value = _uint32_bytes(sorted(range(count), key=value_keys.__getitem__))
    del value_keys
    by_insert = _uint32_bytes(sorted(range(count), key=insert_keys.__getitem__))
    del insert_keys
    sources_json = json.dumps(
        sources, ensure_ascii=False, separators=(",", ":")
    ).encode("utf-8")
    header = HEADER.pack(
        MAGIC,
        count,
        _u32(len(search_blob), "search blob"),
        _u32(len(original_blob), "original blob"),
        _u32(len(sources_json), "sources JSON"),
    )
    return b"".join((header, records, by_value, by_insert, search_blob, original_blob, sources_json))


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _index_matches_manifest(index: Path, metadata: dict) -> bool:
    """Validate the binary contract without allocating the expanded index."""
    expected_digest = metadata.get("indexSha256")
    if (
        not isinstance(expected_digest, str)
        or len(expected_digest) != 64
        or any(character not in "0123456789abcdef" for character in expected_digest)
    ):
        return False
    with ZipFile(index) as archive:
        if archive.namelist() != [INDEX_MEMBER]:
            return False
        member = archive.getinfo(INDEX_MEMBER)
        with archive.open(member) as stream:
            header = stream.read(HEADER.size)
            if len(header) != HEADER.size:
                return False
            magic, count, search_size, original_size, sources_size = HEADER.unpack(header)
            if magic != MAGIC or count != metadata["count"]:
                return False
            expected_size = (
                HEADER.size + count * (RECORD.size + 8)
                + search_size + original_size + sources_size
            )
            if member.file_size != expected_size:
                return False
            digest = hashlib.sha256(header)
            actual_size = len(header)
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                actual_size += len(block)
                digest.update(block)
            return actual_size == expected_size and digest.hexdigest() == expected_digest


def outputs_are_current(source: Path, index: Path, bootstrap: Path) -> bool:
    """Check source/archive identity and the binary contract used by the app."""
    if not all(Path(path).is_file() for path in (source, index, bootstrap)):
        return False
    try:
        metadata = json.loads(Path(bootstrap).read_text(encoding="utf-8"))
        return (
            isinstance(metadata, dict)
            and metadata.get("version") == FORMAT_VERSION
            and _is_int(metadata.get("count"))
            and metadata["count"] >= 0
            and isinstance(metadata.get("suggestions"), list)
            and len(metadata["suggestions"]) == min(10, metadata["count"])
            and metadata.get("sourceSha256") == file_sha256(source)
            and metadata.get("archiveSha256") == file_sha256(index)
            and _index_matches_manifest(index, metadata)
        )
    except (OSError, ValueError, TypeError, BadZipFile, RuntimeError, EOFError, zlib.error):
        return False


def _compact(candidate: Candidate | tuple) -> dict:
    value, insert_value, source, score, category = candidate
    item = {"v": value, "i": insert_value, "s": source, "r": score}
    if category is not None:
        item["c"] = category
    return item


def build_index(
    source: Path = DEFAULT_SOURCE,
    index: Path = DEFAULT_INDEX,
    bootstrap: Path = DEFAULT_BOOTSTRAP,
    *,
    force: bool = False,
    candidates: Iterable[Candidate | tuple] | None = None,
) -> dict:
    """Generate both assets atomically per file; reruns repair an incomplete pair."""
    source, index, bootstrap = map(Path, (source, index, bootstrap))
    if len({source.resolve(), index.resolve(), bootstrap.resolve()}) != 3:
        raise ValueError("source, index, and bootstrap paths must be distinct")
    if not force and outputs_are_current(source, index, bootstrap):
        result = json.loads(bootstrap.read_text(encoding="utf-8"))
        print(f"Index unchanged: {result['count']:,} candidates -> {index}")
        return result
    normalized = (
        load_candidates_from_zip(source)
        if candidates is None else normalize_candidates(candidates)
    )
    binary = pack_index(normalized)
    metadata = {
        "version": FORMAT_VERSION,
        "count": len(normalized),
        "sourceSha256": file_sha256(source),
        "indexSha256": hashlib.sha256(binary).hexdigest(),
        "suggestions": [_compact(item) for item in normalized[:10]],
    }
    index.parent.mkdir(parents=True, exist_ok=True)
    bootstrap.parent.mkdir(parents=True, exist_ok=True)
    temporary: list[Path] = []
    try:
        with tempfile.NamedTemporaryFile(
            prefix=index.name + ".", suffix=".tmp", dir=index.parent, delete=False
        ) as stream:
            index_temp = Path(stream.name)
        temporary.append(index_temp)
        member = ZipInfo(INDEX_MEMBER, date_time=(1980, 1, 1, 0, 0, 0))
        member.compress_type = ZIP_DEFLATED
        member.external_attr = 0o644 << 16
        with ZipFile(index_temp, "w", compression=ZIP_DEFLATED, compresslevel=3) as archive:
            archive.writestr(member, binary, compresslevel=3)
        metadata["archiveSha256"] = file_sha256(index_temp)
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", prefix=bootstrap.name + ".",
            suffix=".tmp", dir=bootstrap.parent, delete=False,
        ) as stream:
            bootstrap_temp = Path(stream.name)
            temporary.append(bootstrap_temp)
            json.dump(metadata, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(index_temp, index)
        os.replace(bootstrap_temp, bootstrap)
    finally:
        for path in temporary:
            path.unlink(missing_ok=True)
    print(
        f"Built index: {len(normalized):,} candidates, {len(binary):,} binary bytes, "
        f"{index.stat().st_size:,} ZIP bytes -> {index}"
    )
    return metadata


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--output", type=Path, default=DEFAULT_INDEX)
    parser.add_argument("--bootstrap", type=Path, default=DEFAULT_BOOTSTRAP)
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    build_index(args.source, args.output, args.bootstrap, force=args.force)


if __name__ == "__main__":
    main()

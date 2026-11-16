import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'completion_normalization.dart';

/// Exact, canonical Danbooru tags. Each entry is an independent OR rule.
/// Keeping rules local avoids server query limits and preserves raw pagination.
class TagBlocklist extends ChangeNotifier {
  TagBlocklist({Future<SharedPreferences> Function()? loadPreferences})
    : _loadPreferences = loadPreferences ?? SharedPreferences.getInstance;

  static final instance = TagBlocklist();
  static const storageKey = 'tag_blocklist_v1';
  static const maxTags = 2000;

  final Future<SharedPreferences> Function() _loadPreferences;
  SharedPreferences? _preferences;
  Future<void>? _initialization;
  Future<void> _mutationTail = Future<void>.value();
  Set<String> _tags = {};
  bool _enabled = true;
  bool _temporarilyShow = false;
  String? _loadError;
  bool _loaded = false;
  bool _needsReload = false;

  List<String> get tags => List.unmodifiable(_tags.toList()..sort());
  bool get enabled => _enabled;
  bool get temporarilyShow => _temporarilyShow;
  bool get isFiltering => _enabled && !_temporarilyShow && _tags.isNotEmpty;
  bool get loaded => _loaded;
  String? get loadError => _loadError;

  static String canonicalTag(String tag) => normalizeCompletionKey(tag.trim());

  Future<void> initialize() => _initialization ??= _read();

  Future<void> retryLoad() => _enqueue(() async {
    // Finish any initial read and serialize reloads with mutations. An older
    // retry must never publish its snapshot after a newer write has committed.
    await _initialization;
    _initialization = _read();
    await _initialization;
  });

  Future<void> _read() async {
    try {
      final preferences = await _loadPreferences();
      // A new store must also avoid another instance's failed-write cache.
      _needsReload = true;
      await preferences.reload();
      _needsReload = false;
      final raw = preferences.getString(storageKey);
      var tags = <String>{};
      var enabled = true;
      if (raw != null) {
        final decoded = jsonDecode(raw);
        if (decoded is! Map ||
            decoded['version'] != 1 ||
            decoded['enabled'] is! bool ||
            decoded['tags'] is! List) {
          throw const FormatException('Invalid blocklist');
        }
        final values = decoded['tags'] as List;
        if (values.length > maxTags || values.any((tag) => tag is! String)) {
          throw const FormatException('Invalid blocklist tags');
        }
        tags = values.cast<String>().map(_validatedTag).toSet();
        enabled = decoded['enabled'] as bool;
      }
      _preferences = preferences;
      _tags = tags;
      _enabled = enabled;
      _loadError = null;
    } catch (_) {
      // Never overwrite an unreadable configuration with an empty list.
      _loadError = '屏蔽列表无法读取，原始数据已保留。请重试或复制原始数据。';
    } finally {
      _loaded = true;
      notifyListeners();
    }
  }

  static String _validatedTag(String value) {
    final tag = canonicalTag(value);
    if (tag.isEmpty || tag.length > 512 || RegExp(r'\s').hasMatch(tag)) {
      throw const FormatException('请输入完整标签，多个标签用空格或换行分隔');
    }
    return tag;
  }

  bool matches(String tagString) {
    if (_tags.isEmpty) return false;
    return tagString.split(RegExp(r'\s+')).any((tag) {
      return _tags.contains(canonicalTag(tag));
    });
  }

  bool hides(String tagString) => isFiltering && matches(tagString);

  List<String> matchingTags(String tagString) => tagString
      .split(RegExp(r'\s+'))
      .map(canonicalTag)
      .where(_tags.contains)
      .toSet()
      .toList();

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final result = _mutationTail.then((_) => action());
    _mutationTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<T> _mutate<T>(Future<T> Function() action) => _enqueue(() async {
    await initialize();
    if (_loadError != null) throw StateError(_loadError!);
    return action();
  });

  Future<void> _save(Set<String> tags, bool enabled) async {
    if (_needsReload) {
      await _preferences!.reload();
      _needsReload = false;
    }
    try {
      final ok = await _preferences!.setString(
        storageKey,
        jsonEncode({
          'version': 1,
          'enabled': enabled,
          'tags': tags.toList()..sort(),
        }),
      );
      if (!ok) throw StateError('屏蔽设置保存失败，请重试');
    } catch (_) {
      _needsReload = true;
      try {
        await _preferences!.reload();
        _needsReload = false;
      } catch (_) {
        _loadError = '无法确认屏蔽设置是否保存，原有规则仍生效。请重试读取。';
        notifyListeners();
      }
      rethrow;
    }
    _tags = tags;
    _enabled = enabled;
    notifyListeners();
  }

  Future<Set<String>> addTags(
    Iterable<String> values, {
    bool enableFiltering = false,
    bool endTemporaryReveal = true,
  }) => _mutate(() async {
    final requested = values.map(_validatedTag).toSet();
    final added = requested.difference(_tags);
    final updated = {..._tags, ...requested};
    if (updated.length > maxTags) {
      throw const FormatException('最多保存 2000 个屏蔽标签');
    }
    await _save(updated, enableFiltering || _enabled);
    if (endTemporaryReveal && _temporarilyShow) {
      _temporarilyShow = false;
      notifyListeners();
    }
    return added;
  });

  Future<void> removeTags(Iterable<String> values) => _mutate(() async {
    final removed = values.map(canonicalTag).toSet();
    await _save(_tags.difference(removed), _enabled);
  });

  Future<void> setEnabled(bool enabled) =>
      _mutate(() => _save({..._tags}, enabled));

  void setTemporarilyShow(bool value) {
    if (_temporarilyShow == value) return;
    _temporarilyShow = value;
    notifyListeners();
  }

  Future<String> rawBackup() async {
    final preferences = _preferences ?? await _loadPreferences();
    _needsReload = true;
    await preferences.reload();
    _needsReload = false;
    final raw = preferences.get(storageKey);
    return raw is String ? raw : jsonEncode({'value': raw});
  }
}

class TagBlocklistScope extends InheritedNotifier<TagBlocklist> {
  const TagBlocklistScope({
    super.key,
    required TagBlocklist blocklist,
    required super.child,
  }) : super(notifier: blocklist);

  static TagBlocklist of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<TagBlocklistScope>()
          ?.notifier ??
      TagBlocklist.instance;
}

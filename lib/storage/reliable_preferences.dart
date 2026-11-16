import 'package:shared_preferences/shared_preferences.dart';

class PreferencesWriteException extends StateError {
  PreferencesWriteException({required this.recoveryRequired})
    : super(
        recoveryRequired
            ? '本地保存失败，尚未确认恢复。已保留上次确认的数据，请重试恢复后再修改。'
            : '本地保存失败，已恢复原有数据，请重试。',
      );

  final bool recoveryRequired;
}

/// One queue and one confirmed snapshot for every consumer of a plugin cache.
/// Android getAll/reload reads native memory, which can contain failed commits.
class ReliablePreferences {
  ReliablePreferences._(this._preferences)
    : _confirmed = _pluginSnapshot(_preferences);

  static final _instances = Expando<ReliablePreferences>();

  static ReliablePreferences forInstance(SharedPreferences preferences) =>
      _instances[preferences] ??= ReliablePreferences._(preferences);

  final SharedPreferences _preferences;
  Map<String, Object> _confirmed;
  Future<void> _tail = Future<void>.value();
  _Recovery? _recovery;

  bool get recoveryRequired => _recovery != null;
  Set<String> get recoveryKeys =>
      Set.unmodifiable({if (_recovery case final recovery?) recovery.key});

  static Object _copyValue(Object value) {
    if (value is! List) return value;
    if (value.every((item) => item is String)) {
      return List<String>.unmodifiable(value.cast<String>());
    }
    // Preserve corrupt/wrong-type values for a raw backup. They must never
    // prevent unrelated confirmed preferences from being read.
    return List<Object?>.unmodifiable(value);
  }

  static bool _canRestore(Object? value) =>
      value == null ||
      value is String ||
      value is bool ||
      value is int ||
      value is double ||
      value is List<String>;

  static Map<String, Object> _pluginSnapshot(SharedPreferences preferences) => {
    for (final key in preferences.getKeys())
      if (preferences.get(key) case final value?) key: _copyValue(value),
  };

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  /// Wait for writes, then return confirmed values. During uncertain recovery
  /// even an explicit refresh must not adopt the platform's dirty native map.
  Future<Map<String, Object>> readAll({bool refresh = false}) =>
      _enqueue(() async {
        if (refresh && !recoveryRequired) {
          await _preferences.reload();
          _confirmed = _pluginSnapshot(_preferences);
        }
        return Map<String, Object>.unmodifiable(_confirmed);
      });

  Future<void> setString(String key, String value) =>
      _enqueue(() => _write(key, value));

  Future<void> remove(String key) => _enqueue(() => _write(key, null));

  Future<void> recover() => _enqueue(_recover);

  Future<bool> _writeValue(String key, Object? value) => switch (value) {
    null => _preferences.remove(key),
    String value => _preferences.setString(key, value),
    bool value => _preferences.setBool(key, value),
    int value => _preferences.setInt(key, value),
    double value => _preferences.setDouble(key, value),
    List<String> value => _preferences.setStringList(key, value),
    _ => throw StateError('无法恢复未知类型的本地数据。'),
  };

  Future<void> _recover() async {
    final recovery = _recovery;
    if (recovery == null) return;
    try {
      // A positive write acknowledgment, never reload, confirms restoration.
      if (!await _writeValue(recovery.key, recovery.value)) {
        throw PreferencesWriteException(recoveryRequired: true);
      }
    } catch (_) {
      throw PreferencesWriteException(recoveryRequired: true);
    }
    _recovery = null;
  }

  Future<void> _write(String key, Object? value) async {
    // A native commit flushes the whole map. Do not let an unrelated key write
    // publish an earlier failed value; there can only be one unresolved write.
    await _recover();
    final before = _confirmed[key];
    if (!_canRestore(before)) {
      // Refuse before touching native memory: an unknown old type could not
      // be restored if the new value failed to reach persistent storage.
      throw StateError('本地数据类型异常，无法安全覆盖。请先复制备份并修复原始数据。');
    }
    try {
      if (!await _writeValue(key, value)) {
        throw PreferencesWriteException(recoveryRequired: true);
      }
    } catch (_) {
      _recovery = _Recovery(key, before);
      try {
        await _recover();
      } catch (_) {
        // Keep the confirmed snapshot and shared write protection for retry.
      }
      throw PreferencesWriteException(recoveryRequired: recoveryRequired);
    }
    if (value == null) {
      _confirmed.remove(key);
    } else {
      _confirmed[key] = _copyValue(value);
    }
  }
}

class _Recovery {
  const _Recovery(this.key, this.value);
  final String key;
  final Object? value;
}

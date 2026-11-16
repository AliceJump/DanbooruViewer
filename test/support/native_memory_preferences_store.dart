import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'failing_preferences_store.dart';

/// Android-style commit: native memory changes first, getAll reads that memory,
/// and a successful commit publishes the entire native map to disk.
class NativeMemoryPreferencesStore extends SharedPreferencesStorePlatform {
  NativeMemoryPreferencesStore([Map<String, Object> initialValues = const {}])
    : persisted = _copy(initialValues),
      nativeMemory = _copy(initialValues);

  final Map<String, Object> persisted;
  final Map<String, Object> nativeMemory;
  final Map<String, PreferenceFailure> failures = {};
  final List<String> attemptedWrites = [];
  String? heldKey;
  final started = Completer<void>();
  final _release = Completer<void>();

  static Object _copyValue(Object value) =>
      value is List<String> ? List<String>.from(value) : value;
  static Map<String, Object> _copy(Map<String, Object> values) =>
      values.map((key, value) => MapEntry(key, _copyValue(value)));

  Future<SharedPreferences> install() async {
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = this;
    return SharedPreferences.getInstance();
  }

  void release() {
    if (!_release.isCompleted) _release.complete();
  }

  Future<bool> _commit(String key) async {
    attemptedWrites.add(key);
    if (key == heldKey && !started.isCompleted) {
      started.complete();
      await _release.future;
    }
    final failure = failures[key];
    if (failure == PreferenceFailure.throwException) {
      throw StateError('Native disk write failed');
    }
    if (failure == PreferenceFailure.returnFalse) return false;
    persisted
      ..clear()
      ..addAll(_copy(nativeMemory));
    return true;
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) {
    final name = key.substring('flutter.'.length);
    nativeMemory[name] = _copyValue(value);
    return _commit(name);
  }

  @override
  Future<bool> remove(String key) {
    final name = key.substring('flutter.'.length);
    nativeMemory.remove(name);
    return _commit(name);
  }

  @override
  Future<Map<String, Object>> getAll() async => nativeMemory.map(
    (key, value) => MapEntry('flutter.$key', _copyValue(value)),
  );

  @override
  Future<bool> clear() {
    nativeMemory.clear();
    return _commit('');
  }
}

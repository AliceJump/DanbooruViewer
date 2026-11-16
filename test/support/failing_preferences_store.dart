import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

enum PreferenceFailure { returnFalse, throwException }

/// A platform backend whose persisted values are separate from the real
/// SharedPreferences cache. Public keys omit the plugin's `flutter.` prefix.
class FailingPreferencesStore extends SharedPreferencesStorePlatform {
  FailingPreferencesStore([Map<String, Object> initialValues = const {}])
    : persisted = initialValues.map(
        (key, value) => MapEntry(key, _copyValue(value)),
      );

  final Map<String, Object> persisted;
  final Map<String, PreferenceFailure> setFailures = {};
  final Map<String, PreferenceFailure> removeFailures = {};
  final List<String> setCalls = [];
  final List<String> removeCalls = [];
  bool failReads = false;
  int readCount = 0;

  Future<SharedPreferences> install() async {
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = this;
    return SharedPreferences.getInstance();
  }

  static Object _copyValue(Object value) =>
      value is List<String> ? List<String>.from(value) : value;

  static String _unprefixed(String key) {
    const prefix = 'flutter.';
    if (!key.startsWith(prefix)) {
      throw ArgumentError.value(key, 'key', 'Expected the default prefix');
    }
    return key.substring(prefix.length);
  }

  bool _fail(PreferenceFailure failure, String operation, String key) {
    if (failure == PreferenceFailure.throwException) {
      throw StateError('Simulated preferences $operation failure for $key');
    }
    return false;
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    final name = _unprefixed(key);
    setCalls.add(name);
    final failure = setFailures[name];
    if (failure != null) return _fail(failure, 'set', name);
    persisted[name] = _copyValue(value);
    return true;
  }

  @override
  Future<bool> remove(String key) async {
    final name = _unprefixed(key);
    removeCalls.add(name);
    final failure = removeFailures[name];
    if (failure != null) return _fail(failure, 'remove', name);
    persisted.remove(name);
    return true;
  }

  @override
  Future<Map<String, Object>> getAll() async {
    readCount++;
    if (failReads) throw StateError('Simulated preferences read failure');
    return persisted.map(
      (key, value) => MapEntry('flutter.$key', _copyValue(value)),
    );
  }

  @override
  Future<bool> clear() async {
    persisted.clear();
    return true;
  }
}

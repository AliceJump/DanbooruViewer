import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
// The package's URL-only download subjects cannot be cleared on proxy changes.
// A separate WebHelper per revision isolates those subjects while sharing files.
// ignore: implementation_imports
import 'package:flutter_cache_manager/src/cache_store.dart';
// ignore: implementation_imports
import 'package:flutter_cache_manager/src/web/web_helper.dart';

import 'app_network_service.dart';
import 'web_cache_store.dart';

class AppCacheManager {
  AppCacheManager._();

  // Reuse the existing namespace so previously viewed images stay available.
  static final CacheManager instance = _create(
    AppNetworkService.instance,
    memory: kIsWeb,
    cacheKey: 'libCachedImageData',
  );

  @visibleForTesting
  static CacheManager forTesting(
    AppNetworkService service, {
    FileSystem? fileSystem,
  }) => _create(
    service,
    memory: true,
    cacheKey: 'libCachedImageData-test',
    fileSystem: fileSystem,
  );

  static CacheManager _create(
    AppNetworkService service, {
    required bool memory,
    required String cacheKey,
    FileSystem? fileSystem,
  }) {
    final fetcher = _CacheFileService(service)..concurrentFetches = 4;
    final repository = memory ? WebCacheRepository() : null;
    final Config config;
    if (memory) {
      config = Config(
        cacheKey,
        stalePeriod: const Duration(days: 30),
        maxNrOfCacheObjects: 300,
        repo: repository!,
        fileSystem: fileSystem ?? MemoryCacheSystem(),
        fileService: fetcher,
      );
    } else {
      config = Config(
        cacheKey,
        stalePeriod: const Duration(days: 30),
        maxNrOfCacheObjects: 300,
        fileService: fetcher,
      );
    }
    final store = memory
        ? WebCacheStore(config, repository!)
        : CacheStore(config);
    // This public customization constructor is annotated for tests upstream,
    // but is required for Web storage and revision-scoped download subjects.
    // ignore: invalid_use_of_visible_for_testing_member
    return CacheManager.custom(
      config,
      cacheStore: store,
      webHelper: _RevisionWebHelper(store, fetcher, service),
    );
  }
}

class _CacheFileService extends FileService {
  _CacheFileService(AppNetworkService service)
    : _delegate = HttpFileService(httpClient: service.createClient());

  final HttpFileService _delegate;

  @override
  Future<FileServiceResponse> get(
    String url, {
    Map<String, String>? headers,
  }) async {
    final response = await _delegate.get(url, headers: headers);
    // CacheManager consumes bodies only for 200/202. In particular a 304 or a
    // final HTTP error otherwise retains the policy client's request token.
    if (response.statusCode != 200 && response.statusCode != 202) {
      await response.content.listen(null).cancel();
    }
    return response;
  }
}

class _RevisionWebHelper extends WebHelper {
  _RevisionWebHelper(this._store, this._fetcher, this._service)
    : super(_store, _fetcher);

  final CacheStore _store;
  final FileService _fetcher;
  final AppNetworkService _service;
  int? _revision;
  WebHelper? _current;

  @override
  Stream<FileResponse> downloadFile(
    String url, {
    String? key,
    Map<String, String>? authHeaders,
    bool ignoreMemCache = false,
  }) {
    final revision = _service.revision;
    if (_revision != revision) {
      _revision = revision;
      _current = WebHelper(
        _store,
        _RevisionFileService(_fetcher, _service, revision)
          ..concurrentFetches = _fetcher.concurrentFetches,
      );
    }
    return _current!.downloadFile(
      url,
      key: key,
      authHeaders: authHeaders,
      ignoreMemCache: ignoreMemCache,
    );
  }
}

class _RevisionFileService extends FileService {
  _RevisionFileService(this.delegate, this.service, this.revision);

  final FileService delegate;
  final AppNetworkService service;
  final int revision;

  @override
  Future<FileServiceResponse> get(
    String url, {
    Map<String, String>? headers,
  }) async {
    // Old queued requests must not start once a new route has been selected.
    if (service.revision != revision) {
      throw const NetworkCancelledException('网络设置已更改，请重新加载。');
    }
    final response = await delegate.get(url, headers: headers);
    if (service.revision != revision) {
      if (response.statusCode == 200 || response.statusCode == 202) {
        await response.content.listen(null).cancel();
      }
      throw const NetworkCancelledException('网络设置已更改，请重新加载。');
    }
    return response;
  }
}

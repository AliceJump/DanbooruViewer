import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import 'app_network_service.dart';

class AppCacheManager {
  AppCacheManager._();

  // Reuse the existing namespace so previously viewed images stay available.
  static final CacheManager instance = CacheManager(
    Config(
      'libCachedImageData',
      stalePeriod: const Duration(days: 30),
      maxNrOfCacheObjects: 300,
      fileService: HttpFileService(
        httpClient: AppNetworkService.instance.createClient(),
      )..concurrentFetches = 4,
    ),
  );

  @visibleForTesting
  static CacheManager forTesting(AppNetworkService service) => CacheManager(
    Config(
      'libCachedImageData-test',
      stalePeriod: const Duration(days: 30),
      maxNrOfCacheObjects: 300,
      repo: NonStoringObjectProvider(),
      fileSystem: MemoryCacheSystem(),
      fileService: HttpFileService(httpClient: service.createClient())
        ..concurrentFetches = 4,
    ),
  );
}

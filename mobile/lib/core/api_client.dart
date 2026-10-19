import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

abstract final class ApiConfig {
  static const baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://10.0.2.2:8000',
  );
}

final apiClientProvider = Provider<Dio>((ref) {
  final uri = Uri.tryParse(ApiConfig.baseUrl);
  if (uri == null ||
      !uri.hasAuthority ||
      !const ['http', 'https'].contains(uri.scheme)) {
    throw StateError('API_BASE_URL must be an absolute HTTP or HTTPS URL.');
  }
  final dio = Dio(
    BaseOptions(
      baseUrl: ApiConfig.baseUrl.replaceFirst(RegExp(r'/+$'), ''),
      connectTimeout: const Duration(seconds: 15),
      sendTimeout: const Duration(seconds: 60),
      receiveTimeout: const Duration(seconds: 90),
      headers: {'Accept': 'application/json'},
    ),
  );
  ref.onDispose(() => dio.close(force: true));
  return dio;
});

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../core/app_exception.dart';

class SttService {
  SttService(this._dio);
  final Dio _dio;

  /// The caller owns the temporary recording and should remove it in finally.
  /// MultipartFile reads the file as a stream instead of buffering the clip.
  Future<String> transcribe(String filePath) async {
    final file = File(filePath);
    if (!await file.exists() || await file.length() <= 44) {
      throw const AppException('مفيش تسجيل صالح لتحويله لنص.');
    }
    if (await file.length() > 10 * 1024 * 1024) {
      throw const AppException('التسجيل طويل؛ جرّب طلب أقصر من دقيقة.');
    }
    try {
      final response = await _dio.post<Object?>(
        '/transcribe',
        data: FormData.fromMap({
          'file': await MultipartFile.fromFile(
            filePath,
            filename: p.basename(filePath),
          ),
        }),
      );
      final data = response.data;
      if (data is! Map || data['text'] is! String) {
        throw const AppException('خادم تحويل الصوت رجّع استجابة غير صالحة.');
      }
      final text = (data['text'] as String).trim();
      if (text.isEmpty) {
        throw const AppException('ما سمعتش كلام واضح. جرّب تسجّل تاني.');
      }
      return text;
    } on DioException catch (error) {
      if (error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.receiveTimeout ||
          error.type == DioExceptionType.sendTimeout) {
        throw const AppException('تحويل الصوت أخد وقت طويل. جرّب تاني.');
      }
      if (error.type == DioExceptionType.connectionError) {
        throw const AppException(
          'مش قادر أوصل للخادم. اتأكد من الشبكة وعنوان الخادم.',
        );
      }
      if (error.response?.statusCode == 413) {
        throw const AppException('التسجيل طويل؛ جرّب تسجيل أقصر.');
      }
      throw const AppException('تعذّر تحويل الصوت لنص. جرّب تاني بعد شوية.');
    }
  }
}

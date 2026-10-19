import 'package:dio/dio.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'conversation_state.dart';

class ReminderParserService {
  ReminderParserService(this._dio);

  final Dio _dio;

  Future<ReminderDraft> parse(String text, ReminderDraft context) async {
    String timezone;
    var timezoneFallback = false;
    try {
      timezone = await FlutterTimezone.getLocalTimezone();
    } catch (_) {
      // A fallback is always surfaced on the confirmation card before saving.
      timezone = 'Africa/Cairo';
      timezoneFallback = true;
      tzdata.initializeTimeZones();
    }
    final response = await _dio.post<Map<String, dynamic>>(
      '/parse-reminder',
      data: {
        'text': text,
        'timezone': timezone,
        if (context.context.isNotEmpty) 'context': context.context,
      },
    );
    final data = response.data;
    if (data == null) {
      throw const FormatException('The parser returned an empty response.');
    }
    return ReminderDraft.fromJson(
      data,
      timezone: timezone,
      timezoneFallback: timezoneFallback,
    );
  }
}

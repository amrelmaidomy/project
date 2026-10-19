import 'package:flutter_tts/flutter_tts.dart';

import '../core/app_exception.dart';

class TtsService {
  TtsService({FlutterTts? tts}) : _tts = tts ?? FlutterTts();
  final FlutterTts _tts;
  Future<void>? _initialization;

  Future<void> _initialize() async {
    final available = await _tts.isLanguageAvailable('ar-EG');
    if (available != true && available != 1) {
      throw const AppException(
        'نزّل صوت عربي من إعدادات تحويل النص لكلام في الجهاز عشان تسمع الرد.',
      );
    }
    await _tts.setLanguage('ar-EG');
    await _tts.setSpeechRate(0.46);
    await _tts.setPitch(1.0);
    await _tts.awaitSpeakCompletion(true);
  }

  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;
    try {
      await (_initialization ??= _initialize());
    } catch (_) {
      _initialization = null;
      rethrow;
    }
    await _tts.stop();
    final result = await _tts.speak(text.trim());
    if (result != 1) {
      throw const AppException('تعذّر تشغيل الرد الصوتي على الجهاز.');
    }
  }

  Future<void> stop() async {
    await _tts.stop();
  }

  Future<void> dispose() => stop();
}

import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/api_client.dart';
import '../core/app_exception.dart';

/// Playback must finish (or release its player) before the microphone resumes.
abstract interface class ReplyAudioPlayer {
  Future<void> play(String filePath);
  Future<void> stop();
  Future<void> dispose();
}

class _DeviceReplyAudioPlayer implements ReplyAudioPlayer {
  final AudioPlayer _player = AudioPlayer();
  StreamSubscription<void>? _completionSubscription;
  Completer<void>? _finished;

  @override
  Future<void> play(String filePath) async {
    final finished = Completer<void>();
    _finished = finished;
    _completionSubscription = _player.onPlayerComplete.listen(
      (_) {
        if (!finished.isCompleted) finished.complete();
      },
      onError: (Object error, StackTrace stack) {
        if (!finished.isCompleted) finished.completeError(error, stack);
      },
    );
    await _player.play(
      DeviceFileSource(filePath, mimeType: 'audio/wav'),
      ctx: AudioContext(
        android: const AudioContextAndroid(
          contentType: AndroidContentType.speech,
          usageType: AndroidUsageType.assistant,
          audioFocus: AndroidAudioFocus.gainTransientMayDuck,
        ),
      ),
    );
    await finished.future;
  }

  @override
  Future<void> stop() async {
    await _player.stop();
    if (_finished?.isCompleted == false) _finished!.complete();
  }

  @override
  Future<void> dispose() async {
    await _completionSubscription?.cancel();
    await _player.dispose();
  }
}

/// Synthesizes Egyptian Arabic on the configured Habibi backend and plays WAV.
/// No Android system voice is used, and only one utterance owns audio at a time.
class TtsService {
  TtsService({
    Dio? dio,
    ReplyAudioPlayer Function()? playerFactory,
    Future<Directory> Function()? temporaryDirectory,
    Duration? synthesisTimeout,
  }) : _dio = dio ?? Dio(BaseOptions(baseUrl: ApiConfig.baseUrl)),
       _ownsDio = dio == null,
       _playerFactory = playerFactory ?? _DeviceReplyAudioPlayer.new,
       _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory,
       _synthesisTimeout =
           synthesisTimeout ??
           const Duration(
             seconds: int.fromEnvironment(
               'TTS_TIMEOUT_SECONDS',
               defaultValue: 300,
             ),
           );

  static const _maxAudioBytes = 16 * 1024 * 1024;
  final Dio _dio;
  final bool _ownsDio;
  final ReplyAudioPlayer Function() _playerFactory;
  final Future<Directory> Function() _temporaryDirectory;
  final Duration _synthesisTimeout;
  _SpeechJob? _current;
  int _generation = 0;
  bool _disposed = false;

  Future<void> speak(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    if (_disposed) throw StateError('The speech service is disposed.');
    final generation = ++_generation;
    await _cancelCurrent();
    if (_disposed || generation != _generation) return;
    final job = _SpeechJob(generation);
    _current = job;
    try {
      final response = await _wait(
        _dio.post<List<int>>(
          '/synthesize',
          data: {'text': trimmed},
          cancelToken: job.request,
          options: Options(
            responseType: ResponseType.bytes,
            receiveTimeout: _synthesisTimeout,
            sendTimeout: const Duration(seconds: 30),
            headers: {'Accept': 'audio/wav'},
          ),
        ),
        job,
      );
      _checkCurrent(job);
      final data = response.data;
      final contentType =
          response.headers.value(Headers.contentTypeHeader) ?? '';
      if (data == null ||
          data.length < 44 ||
          data.length > _maxAudioBytes ||
          !const [
            'audio/wav',
            'audio/x-wav',
            'audio/wave',
          ].contains(contentType.split(';').first.toLowerCase().trim()) ||
          String.fromCharCodes(data.take(4)) != 'RIFF' ||
          String.fromCharCodes(data.skip(8).take(4)) != 'WAVE') {
        throw const AppException(
          'خادم Habibi رجّع ملف صوت غير صالح. راجع حالة الخادم.',
        );
      }
      final directory = await _wait(_temporaryDirectory(), job);
      _checkCurrent(job);
      final file = File(
        p.join(
          directory.path,
          'habibi-${DateTime.now().microsecondsSinceEpoch}-${job.generation}.wav',
        ),
      );
      job.file = file;
      await file.writeAsBytes(data, flush: true);
      _checkCurrent(job);
      final player = job.player = _playerFactory();
      await _wait(
        player.play(file.path).timeout(const Duration(minutes: 5)),
        job,
      );
    } on _SpeechCancelled {
      // A stopped or superseded response never starts playback later.
    } on DioException catch (error) {
      if (!job.cancelled.isCompleted && !CancelToken.isCancel(error)) {
        throw _requestError(error);
      }
    } on TimeoutException {
      throw const AppException(
        'الرد الصوتي أخد وقت طويل. راجع خادم Habibi وحاول تاني.',
      );
    } on AppException {
      rethrow;
    } catch (_) {
      throw const AppException(
        'تعذّر تشغيل الرد الصوتي. ارفع صوت الوسائط وراجع الخادم.',
      );
    } finally {
      await _release(job);
    }
  }

  Future<T> _wait<T>(Future<T> operation, _SpeechJob job) => Future.any([
    operation,
    job.cancelled.future.then<T>((_) => throw const _SpeechCancelled()),
  ]);

  void _checkCurrent(_SpeechJob job) {
    if (_disposed ||
        job.generation != _generation ||
        job.cancelled.isCompleted) {
      throw const _SpeechCancelled();
    }
  }

  AppException _requestError(DioException error) {
    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.sendTimeout) {
      return const AppException(
        'توليد الصوت أخد وقت طويل. راجع خادم Habibi على اللاب.',
      );
    }
    if (error.type == DioExceptionType.connectionError) {
      return const AppException(
        'مش قادر أوصل لخادم الصوت. شغّل الخادم وراجع الاتصال.',
      );
    }
    return switch (error.response?.statusCode) {
      413 => const AppException(
        'الرد أطول من حد خدمة الصوت. استخدم جملة أقصر.',
      ),
      422 => const AppException('خادم الصوت رفض النص. راجع النص وحالة Habibi.'),
      503 => const AppException(
        'Habibi مش جاهز. راجع ملفات الموديل والصوت المرجعي على اللاب.',
      ),
      _ => const AppException(
        'تعذّر توليد الرد الصوتي. راجع خادم Habibi على اللاب.',
      ),
    };
  }

  Future<void> _release(_SpeechJob job) async {
    try {
      try {
        await job.player?.stop();
      } finally {
        await job.player?.dispose();
      }
    } catch (error) {
      job.releaseError = error;
    } finally {
      try {
        if (await job.file?.exists() == true) await job.file!.delete();
      } finally {
        if (identical(_current, job)) _current = null;
        if (!job.finished.isCompleted) job.finished.complete();
      }
    }
  }

  Future<void> _cancelCurrent() async {
    final job = _current;
    if (job == null) return;
    if (!job.cancelled.isCompleted) job.cancelled.complete();
    job.request.cancel('Speech stopped.');
    await job.finished.future;
    if (job.releaseError != null) {
      throw const AppException(
        'تعذّر إيقاف الصوت السابق. أعد فتح التطبيق قبل التسجيل.',
      );
    }
  }

  Future<void> stop() async {
    ++_generation;
    await _cancelCurrent();
  }

  Future<void> dispose() async {
    _disposed = true;
    try {
      await stop();
    } finally {
      if (_ownsDio) _dio.close(force: true);
    }
  }
}

class _SpeechJob {
  _SpeechJob(this.generation);
  final int generation;
  final CancelToken request = CancelToken();
  final cancelled = Completer<void>();
  final finished = Completer<void>();
  ReplyAudioPlayer? player;
  File? file;
  Object? releaseError;
}

class _SpeechCancelled implements Exception {
  const _SpeechCancelled();
}

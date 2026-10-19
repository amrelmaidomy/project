import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../core/app_exception.dart';

/// Records short, temporary 16 kHz mono PCM WAV clips for Whisper.
class RecorderService {
  RecorderService({
    AudioRecorder? recorder,
    Future<Directory> Function()? temporaryDirectory,
  }) : _recorder = recorder ?? AudioRecorder(),
       _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory;

  final AudioRecorder _recorder;
  final Future<Directory> Function() _temporaryDirectory;
  final Set<String> _temporaryPaths = {};
  Future<void> _pending = Future<void>.value();
  Future<void>? _disposal;
  String? _currentPath;
  bool _recording = false;
  bool _disposed = false;
  bool _disposing = false;

  bool get isRecording => _recording;

  Stream<Amplitude> get amplitude =>
      _recorder.onAmplitudeChanged(const Duration(milliseconds: 200));

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final result = Completer<T>();
    _pending = _pending.then((_) async {
      try {
        result.complete(await operation());
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  Future<void> start() => _serialized(_start);

  Future<void> _start() async {
    if (_disposed || _disposing) {
      throw StateError('Recorder has been disposed.');
    }
    if (_recording) throw const AppException('التسجيل شغال بالفعل.');
    if (!await _recorder.hasPermission()) {
      throw const AppException('اسمح باستخدام الميكروفون عشان أسمع طلبك.');
    }
    if (!await _recorder.isEncoderSupported(AudioEncoder.wav)) {
      throw const AppException('الجهاز مش بيدعم صيغة التسجيل المطلوبة.');
    }
    final directory = await _temporaryDirectory();
    final filePath = p.join(
      directory.path,
      'fakkarni_${DateTime.now().microsecondsSinceEpoch}.wav',
    );
    _temporaryPaths.add(filePath);
    try {
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
          echoCancel: true,
          noiseSuppress: true,
        ),
        path: filePath,
      );
      _currentPath = filePath;
      _recording = true;
    } catch (_) {
      await _delete(filePath);
      rethrow;
    }
  }

  Future<String?> stop() => _serialized(_stop);

  Future<String?> _stop() async {
    if (!_recording) return null;
    final originalPath = _currentPath;
    _recording = false;
    _currentPath = null;
    try {
      final path = await _recorder.stop();
      if (path == null || !await File(path).exists()) {
        if (originalPath != null) await _delete(originalPath);
        throw const AppException('التسجيل ما اتحفظش. جرّب تسجّل تاني.');
      }
      final file = File(path);
      if (await file.length() <= 44) {
        await _delete(path);
        throw const AppException('التسجيل فاضي. جرّب تتكلم أقرب للميكروفون.');
      }
      _temporaryPaths.add(path);
      return path;
    } catch (_) {
      try {
        await _recorder.cancel();
      } catch (_) {
        // Preserve the recording error while still attempting native cleanup.
      }
      if (originalPath != null) await _delete(originalPath);
      rethrow;
    }
  }

  Future<void> cancel() => _serialized(_cancel);

  Future<void> _cancel() async {
    final path = _currentPath;
    _recording = false;
    _currentPath = null;
    try {
      if (!_disposed) await _recorder.cancel();
    } finally {
      if (path != null) await _delete(path);
    }
  }

  Future<void> deleteRecording(String path) async {
    if (_temporaryPaths.contains(path)) await _delete(path);
  }

  Future<void> _delete(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
      _temporaryPaths.remove(path);
    } on FileSystemException {
      // Keep the owned path for a retry during disposal. Cleanup must not hide
      // successful transcription or the original microphone/network error.
    }
  }

  Future<void> dispose() {
    if (_disposal != null) return _disposal!;
    _disposing = true;
    return _disposal = _serialized(() async {
      try {
        await _cancel();
      } finally {
        _disposed = true;
        try {
          await _recorder.dispose();
        } finally {
          for (final path in _temporaryPaths.toList()) {
            await _delete(path);
          }
        }
      }
    });
  }
}

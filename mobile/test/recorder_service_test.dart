import 'dart:async';
import 'dart:io';

import 'package:arabic_voice_reminder/services/recorder_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';

void main() {
  late Directory directory;
  late FakeAudioRecorder native;
  late RecorderService service;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ma3ak_audio_test_');
    native = FakeAudioRecorder();
    service = RecorderService(
      recorder: native,
      temporaryDirectory: () async => directory,
    );
  });

  tearDown(() async {
    await service.dispose();
    await directory.delete(recursive: true);
  });

  test(
    'native stop finishes before cancellation and a new recording',
    () async {
      await service.start();
      native.stopGate = Completer<void>();
      final stopped = service.stop();
      await native.stopStarted.future;
      final cancelled = service.cancel();
      final restarted = service.start();
      // A blocked stop owns the native device until it finishes.
      await Future<void>.delayed(Duration.zero);
      expect(native.calls, ['start', 'stop']);

      native.stopGate!.complete();
      final oldPath = await stopped;
      await cancelled;
      await restarted;
      expect(native.calls, ['start', 'stop', 'cancel', 'start']);
      expect(service.isRecording, isTrue);
      expect(native.path, isNot(oldPath));
      await service.deleteRecording(oldPath!);
      expect(await File(oldPath).exists(), isFalse);
      expect(await File(native.path!).exists(), isTrue);
    },
  );

  test(
    'a failed native stop is cancelled and does not poison the queue',
    () async {
      await service.start();
      final failedPath = native.path!;
      native.failStop = true;
      await expectLater(service.stop(), throwsStateError);
      expect(native.calls, ['start', 'stop', 'cancel']);
      expect(await File(failedPath).exists(), isFalse);
      await service.start();
      expect(service.isRecording, isTrue);
    },
  );

  test(
    'disposal waits for native stop and removes all owned recordings',
    () async {
      await service.start();
      native.stopGate = Completer<void>();
      final stopped = service.stop();
      await native.stopStarted.future;
      final disposed = service.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(native.calls, ['start', 'stop']);
      native.stopGate!.complete();
      await stopped;
      await disposed;
      expect(native.calls, ['start', 'stop', 'cancel', 'dispose']);
      expect(await directory.list().isEmpty, isTrue);
      await expectLater(service.start(), throwsStateError);
    },
  );
}

class FakeAudioRecorder implements AudioRecorder {
  final calls = <String>[];
  final stopStarted = Completer<void>();
  Completer<void>? stopGate;
  bool failStop = false;
  String? path;

  @override
  Future<bool> hasPermission({bool request = true}) async => true;

  @override
  Future<bool> isEncoderSupported(AudioEncoder encoder) async => true;

  @override
  Future<void> start(RecordConfig config, {required String path}) async {
    calls.add('start');
    this.path = path;
    expect(config.encoder, AudioEncoder.wav);
    expect(config.sampleRate, 16000);
    expect(config.numChannels, 1);
    await File(path).writeAsBytes(List<int>.filled(46, 0));
  }

  @override
  Future<String?> stop() async {
    calls.add('stop');
    if (!stopStarted.isCompleted) stopStarted.complete();
    await stopGate?.future;
    if (failStop) throw StateError('Native stop failed.');
    return path;
  }

  @override
  Future<void> cancel() async => calls.add('cancel');

  @override
  Future<void> dispose() async => calls.add('dispose');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

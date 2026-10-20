import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:arabic_voice_reminder/core/app_exception.dart';
import 'package:arabic_voice_reminder/services/tts_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late ReplyAdapter adapter;
  late TestPlayer player;
  late TtsService tts;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('habibi_test_');
    adapter = ReplyAdapter();
    player = TestPlayer();
    final dio = Dio(BaseOptions(baseUrl: 'http://localhost'))
      ..httpClientAdapter = adapter;
    tts = TtsService(
      dio: dio,
      playerFactory: () => player,
      temporaryDirectory: () async => directory,
    );
  });
  tearDown(() async {
    await tts.dispose();
    await directory.delete(recursive: true);
  });

  test(
    'Habibi reply waits for actual audio completion and removes its WAV',
    () async {
      final speaking = tts.speak('معاك');
      await adapter.received.future;
      expect(adapter.options!.path, '/synthesize');
      expect(adapter.options!.data, {'text': 'معاك'});
      adapter.response.complete(audioResponse());
      await player.started.future;
      expect(await File(player.path!).readAsBytes(), wav());
      var completed = false;
      speaking.then((_) => completed = true);
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      player.finished.complete();
      await speaking;
      expect(player.disposed, isTrue);
      expect(await directory.list().toList(), isEmpty);
    },
  );

  test(
    'stop cancels a pending synthesis and a late response cannot play',
    () async {
      final speaking = tts.speak('معاك');
      await adapter.received.future;
      await tts.stop();
      await speaking;
      adapter.response.complete(audioResponse());
      await Future<void>.delayed(Duration.zero);
      expect(player.started.isCompleted, isFalse);
      expect(await directory.list().toList(), isEmpty);
    },
  );

  test(
    'stop awaits player release before acknowledging the microphone handoff',
    () async {
      player.stopGate = Completer<void>();
      final speaking = tts.speak('معاك');
      await adapter.received.future;
      adapter.response.complete(audioResponse());
      await player.started.future;
      var stopped = false;
      final stopping = tts.stop().then((_) => stopped = true);
      await player.stopCalled.future;
      expect(stopped, isFalse);
      player.stopGate!.complete();
      await stopping;
      await speaking;
      expect(player.disposed, isTrue);
      expect(await directory.list().toList(), isEmpty);
    },
  );

  test(
    'backend synthesis failure remains actionable and never plays an error body',
    () async {
      final speaking = tts.speak('معاك');
      final failure = expectLater(
        speaking,
        throwsA(
          isA<AppException>().having(
            (e) => e.message,
            'message',
            contains('Habibi'),
          ),
        ),
      );
      await adapter.received.future;
      adapter.response.complete(
        ResponseBody.fromString(
          '{"detail":"not ready"}',
          503,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          },
        ),
      );
      await failure;
      expect(player.started.isCompleted, isFalse);
      expect(await directory.list().toList(), isEmpty);
    },
  );

  test('non-audio response never creates a playable temporary file', () async {
    final speaking = tts.speak('معاك');
    final failure = expectLater(speaking, throwsA(isA<AppException>()));
    await adapter.received.future;
    adapter.response.complete(
      ResponseBody.fromString(
        'not a WAV',
        200,
        headers: {
          Headers.contentTypeHeader: ['audio/wav'],
        },
      ),
    );
    await failure;
    expect(player.started.isCompleted, isFalse);
    expect(await directory.list().toList(), isEmpty);
  });
}

List<int> wav() {
  final data = ByteData(48);
  void tag(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      data.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  data.setUint32(4, 40, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 24000, Endian.little);
  data.setUint32(28, 48000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  data.setUint32(40, 4, Endian.little);
  return data.buffer.asUint8List();
}

ResponseBody audioResponse() => ResponseBody.fromBytes(
  wav(),
  200,
  headers: {
    Headers.contentTypeHeader: ['audio/wav'],
  },
);

class ReplyAdapter implements HttpClientAdapter {
  final received = Completer<void>();
  final response = Completer<ResponseBody>();
  RequestOptions? options;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    this.options = options;
    received.complete();
    return response.future;
  }

  @override
  void close({bool force = false}) {}
}

class TestPlayer implements ReplyAudioPlayer {
  final started = Completer<void>();
  final finished = Completer<void>();
  final stopCalled = Completer<void>();
  Completer<void>? stopGate;
  String? path;
  bool disposed = false;
  @override
  Future<void> play(String filePath) async {
    path = filePath;
    started.complete();
    await finished.future;
  }

  @override
  Future<void> stop() async {
    if (!stopCalled.isCompleted) stopCalled.complete();
    await stopGate?.future;
    if (!finished.isCompleted) finished.complete();
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

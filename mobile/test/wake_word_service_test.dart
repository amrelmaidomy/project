import 'package:arabic_voice_reminder/features/wake_word/wake_word_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel('com.ma3ak.reminder/wake_word');
  const events = MethodChannel('com.ma3ak.reminder/wake_word/events');
  late Map<String, Object?> native;
  late int acknowledgements;

  setUp(() {
    native = {
      'available': false,
      'demoAvailable': true,
      'enabled': true,
      'listening': false,
      'state': 'detected',
      'profile': 'hey_jarvis',
      'phrase': 'Hey Jarvis',
      'pendingDetection': true,
      'detectionId': 42,
      'score': 0.8,
    };
    acknowledgements = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(events, (_) async => null);
    messenger.setMockMethodCallHandler(methods, (call) async {
      if (call.method == 'acknowledgeDetection') {
        acknowledgements++;
        native = {...native, 'pendingDetection': false};
      }
      return Map<String, Object?>.from(native);
    });
  });
  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(events, null);
    messenger.setMockMethodCallHandler(methods, null);
  });

  test('foreground hit is acknowledged and delivered once', () async {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final service = WakeWordService();
    final hits = <WakeWordDetection>[];
    final subscription = service.detections.listen(hits.add);
    await service.refresh();
    await Future<void>.delayed(Duration.zero);
    await service.refresh();
    await Future<void>.delayed(Duration.zero);
    expect(hits.single.phrase, 'Hey Jarvis');
    expect(acknowledgements, 1);
    await subscription.cancel();
    service.dispose();
    await Future<void>.delayed(Duration.zero);
  });

  test('stopping native listening clears a queued background hit', () async {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    final service = WakeWordService();
    final hits = <WakeWordDetection>[];
    final subscription = service.detections.listen(hits.add);
    await service.refresh();
    await Future<void>.delayed(Duration.zero);
    expect(hits, isEmpty);
    // The user presses Stop on Android's persistent notification while hidden.
    native = {
      ...native,
      'enabled': false,
      'state': 'disabled',
      'pendingDetection': false,
    };
    await service.refresh();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(hits, isEmpty);
    expect(acknowledgements, 0);
    await subscription.cancel();
    service.dispose();
    await Future<void>.delayed(Duration.zero);
  });
}

import 'package:arabic_voice_reminder/core/api_client.dart';
import 'package:arabic_voice_reminder/core/app_exception.dart';
import 'package:arabic_voice_reminder/features/wake_word/wake_word_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel('com.ma3ak.reminder/wake_word');
  const events = MethodChannel('com.ma3ak.reminder/wake_word/events');
  const permissions = MethodChannel('flutter.baseflow.com/permissions/methods');
  late Map<String, Object?> native;
  late int acknowledgements;
  late List<MethodCall> calls;
  late int permissionRequests;

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
    calls = [];
    permissionRequests = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(events, (_) async => null);
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      if (call.method == 'acknowledgeDetection') {
        acknowledgements++;
        native = {...native, 'pendingDetection': false};
      }
      return Map<String, Object?>.from(native);
    });
    messenger.setMockMethodCallHandler(permissions, (call) async {
      if (call.method == 'requestPermissions') {
        permissionRequests++;
        return {for (final id in call.arguments as List<dynamic>) id: 1};
      }
      return null;
    });
  });
  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(events, null);
    messenger.setMockMethodCallHandler(permissions, null);
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

  test(
    'Arabic start passes the backend URL after explicit permissions',
    () async {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      native = {
        'available': true,
        'enabled': false,
        'profile': 'ya_rafiq',
        'state': 'disabled',
      };
      final service = WakeWordService();
      await service.start();
      final start = calls.singleWhere((call) => call.method == 'start');
      expect(start.arguments, {
        'profile': 'ya_rafiq',
        'baseUrl': ApiConfig.baseUrl,
      });
      expect(permissionRequests, 2);
      service.dispose();
      await Future<void>.delayed(Duration.zero);
    },
  );

  test(
    'starting while hidden never requests permissions or starts service',
    () async {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      final service = WakeWordService();
      await expectLater(service.start(), throwsA(isA<AppException>()));
      expect(permissionRequests, 0);
      expect(calls.where((call) => call.method == 'start'), isEmpty);
      service.dispose();
      await Future<void>.delayed(Duration.zero);
    },
  );

  test(
    'Arabic background conversation never opens a competing Flutter recorder',
    () async {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      // Even a malformed/stale pending flag cannot route Arabic native events
      // into the legacy foreground-only ONNX detection path.
      native = {
        ...native,
        'available': true,
        'profile': 'ya_rafiq',
        'phrase': 'يا رفيق',
        'state': 'speaking',
        'reminderRevision': 123,
      };
      final service = WakeWordService();
      final hits = <WakeWordDetection>[];
      final subscription = service.detections.listen(hits.add);
      await service.refresh();
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(hits, isEmpty);
      expect(acknowledgements, 0);
      expect(service.status.reminderRevision, 123);
      await subscription.cancel();
      service.dispose();
      await Future<void>.delayed(Duration.zero);
    },
  );
}

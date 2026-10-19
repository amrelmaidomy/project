import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/app_exception.dart';

final wakeWordServiceProvider = Provider<WakeWordService>((ref) {
  final service = WakeWordService();
  ref.onDispose(service.dispose);
  return service;
});

class WakeWordStatus {
  const WakeWordStatus({
    this.available = false,
    this.demoAvailable = false,
    this.enabled = false,
    this.listening = false,
    this.profile = 'ya_mosaed',
    this.state = 'unavailable',
    this.message =
        'نموذج «يا مساعد» المدرّب غير مرفق. استخدم زر الميكروفون دلوقتي.',
    this.pendingDetection = false,
  });

  final bool available;
  final bool demoAvailable;
  final bool enabled;
  final bool listening;
  final String profile;
  final String state;
  final String message;
  final bool pendingDetection;

  factory WakeWordStatus.fromMap(Map<Object?, Object?> data) => WakeWordStatus(
    available: data['available'] == true,
    demoAvailable: data['demoAvailable'] == true,
    enabled: data['enabled'] == true,
    listening: data['listening'] == true,
    profile: data['profile'] is String
        ? data['profile']! as String
        : 'ya_mosaed',
    state: data['state'] is String ? data['state']! as String : 'unavailable',
    message: data['message'] is String ? data['message']! as String : '',
    pendingDetection: data['pendingDetection'] == true,
  );
}

class WakeWordDetection {
  const WakeWordDetection({
    required this.profile,
    required this.phrase,
    required this.score,
  });
  final String profile;
  final String phrase;
  final double score;
}

/// Native detection is opt-in. A background hit waits for the UI to resume;
/// this class never launches an Android Activity from the background.
class WakeWordService extends ChangeNotifier with WidgetsBindingObserver {
  WakeWordService() {
    _detections = StreamController<WakeWordDetection>.broadcast(
      onListen: _deliverPending,
    );
    WidgetsBinding.instance.addObserver(this);
    if (_supported) {
      _eventsSubscription = _events.receiveBroadcastStream().listen(
        _onEvent,
        onError: (Object error) => _unavailable(error),
      );
    }
  }

  static const _methods = MethodChannel('com.ma3ak.reminder/wake_word');
  static const _events = EventChannel('com.ma3ak.reminder/wake_word/events');
  late final StreamController<WakeWordDetection> _detections;
  StreamSubscription<Object?>? _eventsSubscription;
  Future<void> _operations = Future<void>.value();
  WakeWordStatus _status = const WakeWordStatus();
  WakeWordDetection? _pending;
  int? _pendingId;
  int? _deliveringId;
  int? _lastDeliveredId;
  bool _delivering = false;
  bool _disposed = false;

  WakeWordStatus get status => _status;
  Stream<WakeWordDetection> get detections => _detections.stream;
  bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  bool get _foreground =>
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final complete = Completer<T>();
    _operations = _operations.then((_) async {
      try {
        if (_disposed) throw StateError('Wake-word service has been disposed.');
        complete.complete(await operation());
      } catch (error, stack) {
        complete.completeError(error, stack);
      }
    });
    return complete.future;
  }

  Future<Map<Object?, Object?>> _call(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    if (!_supported) {
      throw MissingPluginException('Wake word requires Android.');
    }
    final response = await _methods
        .invokeMapMethod<Object?, Object?>(method, arguments)
        .timeout(const Duration(seconds: 30));
    if (response == null) {
      throw const AppException('خدمة كلمة التنبيه رجّعت استجابة غير صالحة.');
    }
    _apply(response);
    return response;
  }

  Future<void> refresh() => _serialized(() async {
    try {
      await _call('status');
    } catch (error) {
      _unavailable(error);
    }
  });

  Future<void> start({String profile = 'ya_mosaed'}) => _serialized(() async {
    if (!_foreground) {
      throw const AppException('افتح التطبيق قبل تشغيل ميكروفون كلمة التنبيه.');
    }
    if (!const ['ya_mosaed', 'hey_jarvis'].contains(profile)) {
      throw ArgumentError.value(profile, 'profile');
    }
    // Check readiness before requesting permissions: absent models never
    // produce a misleading listening toggle or an unnecessary prompt.
    try {
      await _call('status');
      if (!(profile == 'ya_mosaed'
          ? _status.available
          : _status.demoAvailable)) {
        throw const AppException(
          'النموذج المطلوب مش مثبت. راجع docs/wake-word.md واستخدم الزر حاليًا.',
        );
      }
      final microphone = await Permission.microphone.request();
      if (!microphone.isGranted) {
        throw const AppException(
          'اسمح باستخدام الميكروفون لتشغيل كلمة التنبيه.',
        );
      }
      final notifications = await Permission.notification.request();
      if (!notifications.isGranted) {
        throw const AppException(
          'اسمح بالإشعارات عشان يظهر إشعار الميكروفون وزر الإيقاف.',
        );
      }
      await _call('start', {'profile': profile});
    } on PlatformException catch (error) {
      throw AppException(error.message ?? 'تعذّر تشغيل كلمة التنبيه.');
    } on MissingPluginException {
      throw const AppException('كلمة التنبيه متاحة في تطبيق Android فقط.');
    }
  });

  Future<void> stop() => _serialized(() async {
    _pending = null;
    _pendingId = null;
    try {
      await _call('stop');
    } on MissingPluginException {
      _unavailable(null);
    }
  });

  /// Completes only after native AudioRecord has released the microphone.
  /// A failure propagates so the assistant does not open a competing recorder.
  Future<void> pauseForRecording() => _serialized(() async {
    if (!_supported) return;
    try {
      await _call('pause');
    } on MissingPluginException {
      // No native bridge means there is no native wake microphone to release.
      _unavailable(null);
    } on PlatformException catch (error) {
      throw AppException(
        error.message ?? 'ميكروفون كلمة التنبيه لسه بيقفل. جرّب تاني.',
      );
    }
  });

  /// Does not create a service or enable a feature that the user has stopped.
  Future<void> resumeAfterRecording() => _serialized(() async {
    if (!_status.enabled || _pending != null) return;
    try {
      await _call('resume');
    } catch (error) {
      _unavailable(error);
    }
  });

  void _onEvent(Object? event) {
    if (event is Map) _apply(Map<Object?, Object?>.from(event));
  }

  void _apply(Map<Object?, Object?> data) {
    if (_disposed) return;
    _status = WakeWordStatus.fromMap(data);
    if (!_status.enabled && !_status.pendingDetection) {
      _pending = null;
      _pendingId = null;
    }
    final score = data['score'];
    final detectionId = data['detectionId'];
    if (_status.pendingDetection &&
        detectionId is int &&
        detectionId != _pendingId &&
        detectionId != _deliveringId &&
        detectionId != _lastDeliveredId &&
        score is num &&
        score.isFinite &&
        score >= 0 &&
        score <= 1) {
      _pendingId = detectionId;
      _pending = WakeWordDetection(
        profile: _status.profile,
        phrase: data['phrase'] is String
            ? data['phrase']! as String
            : _status.profile,
        score: score.toDouble(),
      );
    }
    notifyListeners();
    _deliverPending();
  }

  void _deliverPending() {
    if (_disposed ||
        !_foreground ||
        !_detections.hasListener ||
        _pending == null ||
        _delivering) {
      return;
    }
    _delivering = true;
    final detection = _pending!;
    final detectionId = _pendingId;
    _deliveringId = detectionId;
    _pending = null;
    _pendingId = null;
    // Acknowledge once so reattaching an EventChannel does not repeat a hit.
    unawaited(
      _serialized(() async {
        try {
          await _call('acknowledgeDetection');
          if (!_disposed && _foreground && _status.enabled) {
            _lastDeliveredId = detectionId;
            _detections.add(detection);
          } else if (!_disposed && _status.enabled) {
            _pending = detection;
            _pendingId = detectionId;
          }
        } catch (_) {
          if (!_disposed && _status.enabled) {
            _pending = detection;
            _pendingId = detectionId;
          }
        } finally {
          _delivering = false;
          _deliveringId = null;
        }
      }),
    );
  }

  void _unavailable(Object? error) {
    if (_disposed) return;
    _status = WakeWordStatus(
      message: error is PlatformException
          ? error.message ?? 'خدمة كلمة التنبيه غير متاحة.'
          : 'كلمة التنبيه تحتاج Android ونماذج ONNX المثبتة. زر الميكروفون متاح.',
    );
    _pending = null;
    _pendingId = null;
    notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(refresh().then((_) => _deliverPending()));
    }
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_eventsSubscription?.cancel() ?? Future<void>.value());
    unawaited(_detections.close());
    // Do not disable a user-started foreground service when an engine detaches.
    super.dispose();
  }
}

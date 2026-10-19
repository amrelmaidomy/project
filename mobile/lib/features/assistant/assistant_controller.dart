import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:record/record.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../core/api_client.dart';
import '../../core/app_exception.dart';
import '../../core/providers.dart';
import '../../services/recorder_service.dart';
import '../../services/stt_service.dart';
import '../../services/tts_service.dart';
import '../reminders/models/reminder.dart';
import '../reminders/services/reminder_repository.dart';
import '../wake_word/wake_word_service.dart';
import 'conversation_state.dart';
import 'reminder_parser_service.dart';

final reminderParserServiceProvider = Provider<ReminderParserService>(
  (ref) => ReminderParserService(ref.watch(apiClientProvider)),
);

final assistantControllerProvider =
    StateNotifierProvider<AssistantController, ConversationState>((ref) {
      final wakeWord = ref.watch(wakeWordServiceProvider);
      return AssistantController(
        recorder: ref.watch(recorderServiceProvider),
        stt: ref.watch(sttServiceProvider),
        tts: ref.watch(ttsServiceProvider),
        parser: ref.watch(reminderParserServiceProvider),
        repository: ref.watch(reminderRepositoryProvider),
        pauseWakeWord: wakeWord.pauseForRecording,
        resumeWakeWord: wakeWord.resumeAfterRecording,
      );
    });

/// Coordinates one conversation at a time. Parsing can never persist a reminder.
class AssistantController extends StateNotifier<ConversationState> {
  AssistantController({
    required RecorderService recorder,
    required SttService stt,
    required TtsService tts,
    required ReminderParserService parser,
    required ReminderRepository repository,
    Future<void> Function()? pauseWakeWord,
    Future<void> Function()? resumeWakeWord,
  }) : _recorder = recorder,
       _stt = stt,
       _tts = tts,
       _parser = parser,
       _repository = repository,
       _pauseWakeWord = pauseWakeWord,
       _resumeWakeWord = resumeWakeWord,
       super(const ConversationState());

  final RecorderService _recorder;
  final SttService _stt;
  final TtsService _tts;
  final ReminderParserService _parser;
  final ReminderRepository _repository;
  final Future<void> Function()? _pauseWakeWord;
  final Future<void> Function()? _resumeWakeWord;
  Timer? _recordingLimit;
  StreamSubscription<Amplitude>? _amplitudeSubscription;
  Completer<void>? _voiceStartFinished;
  Completer<void>? _voiceStopFinished;
  Future<void>? _cancelFuture;
  int _generation = 0;
  bool _disposed = false;

  bool _current(int generation) => !_disposed && generation == _generation;

  /// Wake-word callbacks and the on-screen microphone share this entry point.
  Future<void> startVoice() async {
    if (_disposed ||
        state.isBusy ||
        state.saveUncertain ||
        _cancelFuture != null) {
      return;
    }
    final generation = ++_generation;
    final startFinished = Completer<void>();
    _voiceStartFinished = startFinished;
    state = state.copyWith(
      phase: AssistantPhase.preparing,
      clearError: true,
      microphoneActive: false,
      clearLastSubmittedText: true,
      clearTranscript: true,
    );
    try {
      await _pauseWakeWord?.call();
      if (!_current(generation)) return;
      // speak() awaits TTS completion so the assistant never records its voice.
      await _stopTtsSafely();
      if (!_current(generation)) return;
      await _speakSafely('معاك', generation);
      if (!_current(generation)) return;
      await _recorder.start();
      if (!_current(generation)) {
        await _recorder.cancel();
        return;
      }
      final startedAt = DateTime.now();
      state = state.copyWith(
        phase: AssistantPhase.recording,
        microphoneActive: true,
        recordingStartedAt: startedAt,
      );
      var heardSpeech = false;
      DateTime? silenceSince;
      _amplitudeSubscription = _recorder.amplitude.listen(
        (amplitude) {
          if (!_current(generation) || !state.microphoneActive) return;
          final now = DateTime.now();
          if (amplitude.current > -38) {
            heardSpeech = true;
            silenceSince = null;
          } else if (heardSpeech) {
            silenceSince ??= now;
            if (now.difference(silenceSince!).inMilliseconds >= 1600 &&
                now.difference(startedAt).inMilliseconds >= 2400) {
              unawaited(stopVoice());
            }
          }
        },
        onError: (Object _) {
          // Amplitude is optional. Manual stop and the hard limit still work.
        },
      );
      _recordingLimit = Timer(const Duration(seconds: 60), () {
        if (_current(generation)) unawaited(stopVoice());
      });
    } catch (error) {
      if (!_current(generation)) return;
      await _cancelRecorderSafely();
      if (!_current(generation)) return;
      _fail(
        error is AppException
            ? error.message
            : 'مش قادر أبدأ التسجيل. اتأكد إن صلاحية الميكروفون مفعّلة، '
                  'أو اكتب التذكير تحت.',
      );
      await _resumeWakeWordSafely(generation);
    } finally {
      startFinished.complete();
      if (identical(_voiceStartFinished, startFinished)) {
        _voiceStartFinished = null;
      }
    }
  }

  Future<void> stopVoice() async {
    if (_disposed || state.phase != AssistantPhase.recording) return;
    final generation = _generation;
    // Change phase synchronously before any await to guard double-stop.
    state = state.copyWith(
      phase: AssistantPhase.transcribing,
      microphoneActive: false,
      clearRecordingStartedAt: true,
    );
    final stopFinished = Completer<void>();
    _voiceStopFinished = stopFinished;
    String? path;
    try {
      try {
        await _stopRecordingWatchers();
        path = await _recorder.stop();
      } finally {
        stopFinished.complete();
        if (identical(_voiceStopFinished, stopFinished)) {
          _voiceStopFinished = null;
        }
      }
      if (!_current(generation)) return;
      if (path == null) {
        throw const FormatException('No recorded audio.');
      }
      // The microphone has stopped before the upload begins.
      final text = (await _stt.transcribe(path)).trim();
      if (!_current(generation)) return;
      if (text.isEmpty) {
        _fail('ماسمعتش كلام واضح. جرّب تسجل تاني، أو اكتب التذكير.');
        return;
      }
      state = state.copyWith(latestTranscript: text);
      await _parseText(text, generation);
    } catch (error) {
      if (_current(generation)) {
        _fail(
          _networkMessage(
            error,
            'ماقدرتش أحوّل الصوت لكلام. جرّب تاني، أو اكتب التذكير تحت.',
          ),
        );
      }
    } finally {
      if (path != null) {
        try {
          await _recorder.deleteRecording(path);
        } catch (_) {
          // Temporary-file cleanup must not hide a successful transcription.
        }
      }
      await _resumeWakeWordSafely(generation);
    }
  }

  Future<void> submitText(String value) async {
    final text = value.trim();
    if (_disposed || text.isEmpty || state.isBusy || state.saveUncertain) {
      return;
    }
    final generation = ++_generation;
    state = state.copyWith(phase: AssistantPhase.parsing, clearError: true);
    try {
      await _pauseWakeWord?.call();
      await _stopTtsSafely();
      if (!_current(generation)) return;
      await _parseText(text, generation);
    } catch (_) {
      if (_current(generation)) {
        _fail(
          'مش قادر أبدأ المحادثة الصوتية. أوقف الاستماع التلقائي وجرّب تاني.',
        );
      }
    } finally {
      await _resumeWakeWordSafely(generation);
    }
  }

  Future<void> retryLastText() async {
    final text = state.lastSubmittedText;
    if (text != null) await submitText(text);
  }

  Future<void> _parseText(String text, int generation) async {
    if (!_current(generation)) return;
    state = state.copyWith(
      phase: AssistantPhase.parsing,
      clearError: true,
      lastSubmittedText: text,
      messages: [
        ...state.messages,
        ConversationMessage(text: text, isUser: true),
      ],
    );
    try {
      final draft = await _parser.parse(text, state.draft);
      if (!_current(generation)) return;
      final message = draft.isComplete
          ? _confirmationMessage(draft)
          : draft.question ?? _missingQuestion(draft);
      state = state.copyWith(
        draft: draft,
        phase: draft.isComplete
            ? AssistantPhase.awaitingConfirmation
            : AssistantPhase.awaitingDetails,
        messages: [
          ...state.messages,
          ConversationMessage(text: message, isUser: false),
        ],
      );
      await _speakSafely(message, generation);
    } catch (error) {
      if (_current(generation)) {
        _fail(
          _networkMessage(
            error,
            'ماقدرتش أفهم التذكير دلوقتي. جرّب تاني، أو عدّل النص.',
          ),
        );
      }
    }
  }

  /// This is the only path from the conversation to a stored reminder.
  Future<void> confirm() async {
    if (_disposed ||
        state.phase != AssistantPhase.awaitingConfirmation ||
        !state.draft.isComplete) {
      return;
    }
    final generation = ++_generation;
    final draft = state.draft;
    state = state.copyWith(phase: AssistantPhase.saving, clearError: true);
    try {
      await _pauseWakeWord?.call();
      await _stopTtsSafely();
      if (!_current(generation)) return;
      // The repository schedules notifications and compensates on failure.
      await _repository.create(
        Reminder(
          title: draft.title!,
          eventDateTime: draft.eventDateTime!,
          reminderDateTime: draft.reminderDateTime!,
        ),
      );
      if (!_current(generation)) return;
      const message = 'تمام، سجلت التذكير وهفكرك في معاده.';
      state = state.copyWith(
        phase: AssistantPhase.idle,
        draft: const ReminderDraft(),
        clearLastSubmittedText: true,
        clearTranscript: true,
        messages: [
          ...state.messages,
          const ConversationMessage(text: message, isUser: false),
        ],
      );
      await _speakSafely(message, generation);
    } catch (error) {
      if (!_current(generation)) return;
      state = state.copyWith(
        phase: error is ReminderConsistencyException
            ? AssistantPhase.error
            : AssistantPhase.awaitingConfirmation,
        saveUncertain: error is ReminderConsistencyException,
        error: error is AppException
            ? error.message
            : 'التذكير لسه ماتحفظش. اتأكد إن صلاحيات الإشعارات '
                  'والمنبّهات الدقيقة مفعّلة، وإن الموعد في المستقبل، وجرّب تاني.',
      );
    } finally {
      await _resumeWakeWordSafely(generation);
    }
  }

  void edit() {
    if (_disposed ||
        state.isBusy ||
        state.saveUncertain ||
        !state.draft.isComplete) {
      return;
    }
    final generation = ++_generation;
    state = state.copyWith(
      phase: AssistantPhase.awaitingDetails,
      clearError: true,
      messages: [
        ...state.messages,
        const ConversationMessage(
          text: 'تحب تعدّل إيه؟ اكتب أو قول التفاصيل الجديدة.',
          isUser: false,
        ),
      ],
    );
    unawaited(_stopTtsSafely().then((_) => _resumeWakeWordSafely(generation)));
  }

  Future<void> cancel() {
    if (_cancelFuture != null) return _cancelFuture!;
    if (_disposed || state.phase == AssistantPhase.saving) {
      return Future<void>.value();
    }
    final future = _cancel();
    _cancelFuture = future;
    unawaited(future.whenComplete(() => _cancelFuture = null));
    return future;
  }

  Future<void> _cancel() async {
    final generation = ++_generation;
    final pendingStart = _voiceStartFinished;
    final pendingStop = _voiceStopFinished;
    final watchersStopped = _stopRecordingWatchers();
    // Keep resource acquisition blocked until any earlier start has unwound.
    state = const ConversationState(phase: AssistantPhase.preparing);
    await _stopTtsSafely();
    await pendingStart?.future;
    await pendingStop?.future;
    await watchersStopped;
    try {
      await _recorder.cancel();
    } catch (_) {
      // State still resets when the platform already released its recorder.
    }
    if (_current(generation)) {
      state = const ConversationState();
      await _resumeWakeWordSafely(generation);
    }
  }

  Future<void> startOver() => cancel();

  Future<void> _stopRecordingWatchers() async {
    _recordingLimit?.cancel();
    _recordingLimit = null;
    final subscription = _amplitudeSubscription;
    _amplitudeSubscription = null;
    try {
      await subscription?.cancel();
    } catch (_) {
      // The platform may already have closed its amplitude stream.
    }
  }

  void _fail(String message) {
    state = state.copyWith(
      phase: AssistantPhase.error,
      error: message,
      microphoneActive: false,
      clearRecordingStartedAt: true,
    );
  }

  Future<void> _speakSafely(String text, int generation) async {
    if (!_current(generation)) return;
    try {
      await _tts.speak(text);
    } catch (_) {
      // A missing Android Arabic voice does not block the visible conversation.
    }
  }

  Future<void> _stopTtsSafely() async {
    try {
      await _tts.stop();
    } catch (_) {
      // Text input and recording remain usable without a device TTS engine.
    }
  }

  Future<void> _cancelRecorderSafely() async {
    try {
      await _recorder.cancel();
    } catch (_) {
      // Cleanup may race with provider disposal or a closed native recorder.
    }
  }

  Future<void> _resumeWakeWordSafely(int generation) async {
    if (!_current(generation) || state.isBusy || state.saveUncertain) return;
    try {
      await _resumeWakeWord?.call();
    } catch (_) {
      // Optional wake-word errors are surfaced by its own opt-in UI.
    }
  }

  String _missingQuestion(ReminderDraft draft) {
    if (draft.ambiguousFields.contains('time')) {
      return 'الساعة دي صباحًا ولا مساءً؟';
    }
    if (draft.title == null) return 'إيه اسم الحدث اللي أفكرك بيه؟';
    if (draft.date == null) return 'الموعد يوم إيه؟';
    if (draft.time == null) return 'الساعة كام؟ قول صباحًا أو مساءً.';
    if (draft.remindBeforeMinutes == null) {
      return 'أفكرك قبل الموعد بقد إيه؟';
    }
    return 'محتاج أتأكد من الموعد. اكتب التاريخ والساعة بوضوح.';
  }

  String _confirmationMessage(ReminderDraft draft) {
    DateTime display(DateTime value) => draft.timezoneFallback
        ? tz.TZDateTime.from(value, tz.getLocation(draft.timezone))
        : value.toLocal();
    final event = display(draft.eventDateTime!);
    final reminder = display(draft.reminderDateTime!);
    const weekdays = [
      'الاثنين',
      'الثلاثاء',
      'الأربعاء',
      'الخميس',
      'الجمعة',
      'السبت',
      'الأحد',
    ];
    const months = [
      'يناير',
      'فبراير',
      'مارس',
      'أبريل',
      'مايو',
      'يونيو',
      'يوليو',
      'أغسطس',
      'سبتمبر',
      'أكتوبر',
      'نوفمبر',
      'ديسمبر',
    ];
    String day(DateTime value) =>
        '${weekdays[value.weekday - 1]} ${value.day} ${months[value.month - 1]}';
    String clock(DateTime value) {
      final hour = value.hour % 12 == 0 ? 12 : value.hour % 12;
      final minutes = value.minute == 0 ? '' : ' و${value.minute} دقيقة';
      return '$hour$minutes ${value.hour < 12 ? 'صباحًا' : 'مساءً'}';
    }

    final sameDay =
        event.year == reminder.year &&
        event.month == reminder.month &&
        event.day == reminder.day;
    final zone = draft.timezoneFallback ? ' بتوقيت القاهرة' : '';
    return 'تمام. ${draft.title}، ${day(event)} الساعة ${clock(event)}$zone. '
        'وهفكرك ${sameDay ? '' : '${day(reminder)} '}الساعة ${clock(reminder)}. '
        'راجع التفاصيل واضغط «تأكيد وحفظ» علشان أسجّل التذكير.';
  }

  String _networkMessage(Object error, String fallback) {
    if (error is DioException) {
      if (error.type == DioExceptionType.connectionError ||
          error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.receiveTimeout ||
          error.type == DioExceptionType.sendTimeout) {
        return 'مش قادر أوصل لخدمة المساعد. اتأكد إن الخادم شغّال '
            'واتصال الإنترنت متاح، وبعدين جرّب تاني.';
      }
      if (error.response?.statusCode == 503) {
        return 'خدمة تحويل الصوت مش جاهزة على الخادم. '
            'تقدر تستخدم الكتابة دلوقتي.';
      }
    }
    return fallback;
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    unawaited(_stopRecordingWatchers());
    unawaited(_cancelRecorderSafely());
    unawaited(_stopTtsSafely());
    super.dispose();
  }
}

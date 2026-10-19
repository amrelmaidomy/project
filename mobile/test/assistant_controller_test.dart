import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:record/record.dart';

import 'package:arabic_voice_reminder/features/assistant/assistant_controller.dart';
import 'package:arabic_voice_reminder/core/app_exception.dart';
import 'package:arabic_voice_reminder/features/assistant/assistant_screen.dart';
import 'package:arabic_voice_reminder/features/assistant/conversation_state.dart';
import 'package:arabic_voice_reminder/features/assistant/reminder_parser_service.dart';
import 'package:arabic_voice_reminder/features/reminders/models/reminder.dart';
import 'package:arabic_voice_reminder/features/reminders/services/reminder_repository.dart';
import 'package:arabic_voice_reminder/services/recorder_service.dart';
import 'package:arabic_voice_reminder/services/stt_service.dart';
import 'package:arabic_voice_reminder/services/tts_service.dart';

void main() {
  late _Parser parser;
  late _Repository repository;
  late _Recorder recorder;
  late _Tts tts;
  late AssistantController controller;
  late List<String> calls;

  setUp(() {
    calls = [];
    parser = _Parser();
    repository = _Repository();
    recorder = _Recorder(calls);
    tts = _Tts(calls);
    controller = AssistantController(
      recorder: recorder,
      stt: _Stt(calls),
      tts: tts,
      parser: parser,
      repository: repository,
      pauseWakeWord: () async => calls.add('pauseWake'),
      resumeWakeWord: () async => calls.add('resumeWake'),
    );
  });

  tearDown(() {
    if (controller.mounted) controller.dispose();
  });

  test(
    'a complete parse waits for an explicit confirmation before saving',
    () async {
      parser.results.add(_complete);
      await controller.submitText('دكتور بكرة الساعة خمسة مساءً قبلها ساعتين');

      expect(controller.state.phase, AssistantPhase.awaitingConfirmation);
      expect(repository.saved, isEmpty);

      await controller.confirm();
      expect(repository.saved.single.title, 'دكتور');
      expect(controller.state.phase, AssistantPhase.idle);
      expect(controller.state.draft.title, isNull);
      expect(controller.state.lastSubmittedText, isNull);
      await controller.retryLastText();
      expect(parser.contexts, hasLength(1));
      await controller.confirm();
      expect(repository.saved, hasLength(1));
    },
  );

  test(
    'follow-up requests keep known slots without saving incomplete data',
    () async {
      parser.results.add(
        const ReminderDraft(
          title: 'دكتور',
          date: '2026-10-22',
          missingFields: ['time', 'remind_before'],
          question: 'الساعة كام؟',
        ),
      );
      await controller.submitText('دكتور الخميس');
      expect(controller.state.phase, AssistantPhase.awaitingDetails);
      await controller.confirm();
      expect(repository.saved, isEmpty);

      parser.results.add(_complete);
      await controller.submitText('خمسة مساءً قبلها ساعتين');
      expect(parser.contexts.last.context, {
        'title': 'دكتور',
        'date': '2026-10-22',
      });
      expect(controller.state.phase, AssistantPhase.awaitingConfirmation);
      expect(repository.saved, isEmpty);
    },
  );

  test('an ambiguous hour never reaches the save path', () async {
    parser.results.add(
      const ReminderDraft(
        title: 'دكتور',
        date: '2026-10-22',
        remindBeforeMinutes: 120,
        ambiguousFields: ['time'],
        question: 'خمسة صباحًا ولا مساءً؟',
      ),
    );
    await controller.submitText('دكتور الخميس الساعة خمسة قبلها ساعتين');
    await controller.confirm();
    expect(controller.state.phase, AssistantPhase.awaitingDetails);
    expect(repository.saved, isEmpty);
  });

  test(
    'cancelling discards a late parser response and resets context',
    () async {
      final response = Completer<ReminderDraft>();
      parser.pending = response;
      final submitting = controller.submitText('دكتور الخميس');
      await Future<void>.delayed(Duration.zero);
      expect(controller.state.phase, AssistantPhase.parsing);
      await controller.cancel();
      response.complete(_complete);
      await submitting;

      expect(controller.state.phase, AssistantPhase.idle);
      expect(controller.state.messages, isEmpty);
      expect(controller.state.draft.context, isEmpty);
      expect(repository.saved, isEmpty);
    },
  );

  test(
    'acknowledgement finishes before recording; mic stops before upload',
    () async {
      parser.results.add(_complete);
      final acknowledged = Completer<void>();
      tts.speechGate = acknowledged;
      final starting = controller.startVoice();
      await Future<void>.delayed(Duration.zero);
      expect(calls, contains('say:معاك'));
      expect(calls.indexOf('pauseWake'), lessThan(calls.indexOf('say:معاك')));
      expect(calls, isNot(contains('record')));
      acknowledged.complete();
      await starting;
      expect(calls.indexOf('say:معاك'), lessThan(calls.indexOf('record')));
      expect(controller.state.microphoneActive, isTrue);
      await controller.stopVoice();
      expect(
        calls.indexOf('stopRecording'),
        lessThan(calls.indexOf('transcribe')),
      );
      expect(calls, contains('deleteRecording'));
      expect(controller.state.latestTranscript, 'دكتور الخميس خمسة مساءً');
      expect(controller.state.microphoneActive, isFalse);
      expect(repository.saved, isEmpty);
      expect(calls.last, 'resumeWake');
    },
  );

  test('a missing local TTS voice still permits recording', () async {
    tts.failSpeech = true;
    await controller.startVoice();
    expect(controller.state.phase, AssistantPhase.recording);
    expect(calls, contains('record'));
    await controller.cancel();
  });

  test(
    'cancel blocks a new recording until an in-flight start is released',
    () async {
      final started = Completer<void>();
      recorder.startGate = started;
      final start = controller.startVoice();
      await Future<void>.delayed(Duration.zero);
      final cancellation = controller.cancel();
      await controller.startVoice();
      expect(calls.where((call) => call == 'record'), hasLength(1));
      expect(controller.state.isBusy, isTrue);
      started.complete();
      await start;
      await cancellation;
      expect(controller.state.phase, AssistantPhase.idle);
      recorder.startGate = null;
      await controller.startVoice();
      expect(controller.state.phase, AssistantPhase.recording);
      await controller.cancel();
    },
  );

  test(
    'cancellation during native stop discards audio before upload',
    () async {
      await controller.startVoice();
      final stopped = Completer<String?>();
      recorder.stopGate = stopped;
      final stopping = controller.stopVoice();
      await Future<void>.delayed(Duration.zero);
      final cancelling = controller.cancel();
      await controller.startVoice();
      expect(controller.state.isBusy, isTrue);
      stopped.complete('/tmp/assistant-test.wav');
      await stopping;
      await cancelling;
      expect(calls, isNot(contains('transcribe')));
      expect(calls, contains('deleteRecording'));
      expect(controller.state.phase, AssistantPhase.idle);
      expect(repository.saved, isEmpty);
    },
  );

  test('a save in progress ignores repeated confirmations', () async {
    parser.results.add(_complete);
    await controller.submitText('دكتور الخميس خمسة مساءً');
    final saving = Completer<Reminder>();
    repository.pending = saving;
    final first = controller.confirm();
    await Future<void>.delayed(Duration.zero);
    await controller.confirm();
    expect(repository.saved, hasLength(1));
    saving.complete(repository.saved.single.copyWith(id: 1));
    await first;
    expect(controller.state.phase, AssistantPhase.idle);
  });

  test(
    'uncertain rollback requires a reset before any new save attempt',
    () async {
      parser.results.add(_complete);
      await controller.submitText('دكتور الخميس خمسة مساءً');
      repository.failure = const ReminderConsistencyException(
        'راجع قائمة التذكيرات قبل المحاولة تاني.',
      );
      await controller.confirm();
      expect(controller.state.saveUncertain, isTrue);
      expect(controller.state.error, contains('راجع قائمة التذكيرات'));
      await controller.confirm();
      await controller.submitText('خمسة صباحًا');
      await controller.startVoice();
      expect(repository.saved, hasLength(1));
      expect(parser.contexts, hasLength(1));
      expect(calls, isNot(contains('record')));
      await controller.startOver();
      expect(controller.state.saveUncertain, isFalse);
      expect(controller.state.phase, AssistantPhase.idle);
    },
  );

  testWidgets('text conversation shows details before the user saves', (
    tester,
  ) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const wakeMethods = MethodChannel('com.ma3ak.reminder/wake_word');
    const wakeEvents = MethodChannel('com.ma3ak.reminder/wake_word/events');
    messenger.setMockMethodCallHandler(
      wakeMethods,
      (_) async => {
        'available': false,
        'enabled': false,
        'demoAvailable': false,
      },
    );
    messenger.setMockMethodCallHandler(wakeEvents, (_) async => null);
    addTearDown(() {
      messenger.setMockMethodCallHandler(wakeMethods, null);
      messenger.setMockMethodCallHandler(wakeEvents, null);
    });
    await initializeDateFormatting('ar_EG');
    parser.results.add(_complete);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          assistantControllerProvider.overrideWith((ref) => controller),
        ],
        child: const MaterialApp(
          locale: Locale('ar', 'EG'),
          supportedLocales: [Locale('ar', 'EG')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: AssistantScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'دكتور الخميس خمسة مساءً');
    await tester.tap(find.byTooltip('إرسال النص'));
    await tester.pumpAndSettle();

    expect(find.text('راجع الموعد قبل الحفظ'), findsOneWidget);
    expect(find.text('دكتور'), findsOneWidget);
    expect(repository.saved, isEmpty);
    await tester.ensureVisible(find.text('تأكيد وحفظ'));
    await tester.tap(find.text('تأكيد وحفظ'));
    await tester.pumpAndSettle();
    expect(repository.saved, hasLength(1));
    expect(find.text('تمام، سجلت التذكير وهفكرك في معاده.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

final _complete = ReminderDraft(
  title: 'دكتور',
  date: '2026-10-22',
  time: '17:00',
  remindBeforeMinutes: 120,
  eventDateTime: DateTime.parse('2026-10-22T17:00:00+03:00'),
  reminderDateTime: DateTime.parse('2026-10-22T15:00:00+03:00'),
);

class _Parser extends ReminderParserService {
  _Parser() : super(Dio());
  final results = <ReminderDraft>[];
  final contexts = <ReminderDraft>[];
  Completer<ReminderDraft>? pending;

  @override
  Future<ReminderDraft> parse(String text, ReminderDraft context) async {
    contexts.add(context);
    return pending?.future ?? Future.value(results.removeAt(0));
  }
}

class _Repository implements ReminderRepository {
  final saved = <Reminder>[];
  Completer<Reminder>? pending;
  Object? failure;

  @override
  Future<Reminder> create(Reminder reminder) async {
    saved.add(reminder);
    if (failure != null) throw failure!;
    return pending?.future ?? Future.value(reminder.copyWith(id: 1));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Recorder implements RecorderService {
  _Recorder(this.calls);
  final List<String> calls;
  Completer<void>? startGate;
  Completer<String?>? stopGate;

  @override
  Stream<Amplitude> get amplitude => const Stream<Amplitude>.empty();

  @override
  Future<void> start() async {
    calls.add('record');
    await startGate?.future;
  }

  @override
  Future<String?> stop() async {
    calls.add('stopRecording');
    return stopGate?.future ?? Future.value('/tmp/assistant-test.wav');
  }

  @override
  Future<void> cancel() async {
    calls.add('cancelRecording');
  }

  @override
  Future<void> deleteRecording(String path) async {
    calls.add('deleteRecording');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Stt implements SttService {
  _Stt(this.calls);
  final List<String> calls;

  @override
  Future<String> transcribe(String filePath) async {
    calls.add('transcribe');
    return 'دكتور الخميس خمسة مساءً';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Tts implements TtsService {
  _Tts(this.calls);
  final List<String> calls;
  bool failSpeech = false;
  Completer<void>? speechGate;

  @override
  Future<void> speak(String text) async {
    calls.add('say:$text');
    if (failSpeech) throw StateError('No Arabic voice installed.');
    await speechGate?.future;
  }

  @override
  Future<void> stop() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

import 'package:arabic_voice_reminder/core/providers.dart';
import 'package:arabic_voice_reminder/features/reminders/database/app_database.dart';
import 'package:arabic_voice_reminder/features/reminders/models/reminder.dart';
import 'package:arabic_voice_reminder/features/reminders/services/notification_service.dart';
import 'package:arabic_voice_reminder/main.dart';
import 'package:arabic_voice_reminder/services/recorder_service.dart';
import 'package:arabic_voice_reminder/services/tts_service.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Notifications extends NotificationService {
  final scheduled = <Reminder>[];
  @override
  Future<void> initialize() async {}
  @override
  Future<void> ensureCanSchedule({bool requestPermissions = true}) async {}
  @override
  Future<void> schedule(Reminder reminder) async => scheduled.add(reminder);
  @override
  Future<void> cancel(int id) async {}
}

class _Tts extends TtsService {
  @override
  Future<void> speak(String text) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

class _Recorder extends RecorderService {
  @override
  Future<void> cancel() async {}
  @override
  Future<void> dispose() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const wakeMethods = MethodChannel('com.ma3ak.reminder/wake_word');
  const wakeEvents = MethodChannel('com.ma3ak.reminder/wake_word/events');
  // Android host integration is covered separately; these tests exercise form
  // persistence with an honestly unavailable optional wake model.
  setUp(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      wakeMethods,
      (_) async => {
        'available': false,
        'demoAvailable': false,
        'enabled': false,
        'listening': false,
        'state': 'unavailable',
        'message': 'النموذج غير مثبت',
      },
    );
    messenger.setMockMethodCallHandler(wakeEvents, (_) async => null);
  });
  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(wakeMethods, null);
    messenger.setMockMethodCallHandler(wakeEvents, null);
  });
  testWidgets('manual form persists a reminder and schedules the same row', (
    tester,
  ) async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final notifications = _Notifications();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(database),
          notificationServiceProvider.overrideWithValue(notifications),
          ttsServiceProvider.overrideWithValue(_Tts()),
          recorderServiceProvider.overrideWithValue(_Recorder()),
        ],
        child: const ReminderApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('يومك لسه صفحة جديدة'), findsOneWidget);
    await tester.tap(find.text('تذكير جديد'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, 'مشروع التخرج');
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('حفظ التذكير'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('حفظ التذكير'));
    await tester.pumpAndSettle();
    final saved = await database.allReminders();
    expect(saved.single.title, 'مشروع التخرج');
    expect(notifications.scheduled.single.id, saved.single.id);
    expect(
      saved.single.eventDateTime.difference(saved.single.reminderDateTime),
      const Duration(hours: 2),
    );
    expect(find.text('مشروع التخرج'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('manual form refuses an empty title without scheduling', (
    tester,
  ) async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final notifications = _Notifications();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(database),
          notificationServiceProvider.overrideWithValue(notifications),
          ttsServiceProvider.overrideWithValue(_Tts()),
          recorderServiceProvider.overrideWithValue(_Recorder()),
        ],
        child: const ReminderApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('تذكير جديد'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('حفظ التذكير'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('حفظ التذكير'));
    await tester.pumpAndSettle();
    expect(find.text('اكتب اسم الحدث'), findsOneWidget);
    expect(await database.allReminders(), isEmpty);
    expect(notifications.scheduled, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/reminders/database/app_database.dart';
import '../features/reminders/models/reminder.dart';
import '../features/reminders/services/notification_service.dart';
import '../features/reminders/services/reminder_repository.dart';
import '../services/recorder_service.dart';
import '../services/stt_service.dart';
import '../services/tts_service.dart';
import 'api_client.dart';

final databaseProvider = Provider<AppDatabase>((ref) {
  final database = AppDatabase();
  ref.onDispose(() => unawaited(database.close()));
  return database;
});

final notificationServiceProvider = Provider<NotificationService>(
  (ref) => NotificationService(),
);

final reminderRepositoryProvider = Provider<ReminderRepository>(
  (ref) => ReminderRepository(
    ref.watch(databaseProvider),
    ref.watch(notificationServiceProvider),
  ),
);

final remindersProvider = StreamProvider<List<Reminder>>(
  (ref) => ref.watch(reminderRepositoryProvider).watchAll(),
);

final recorderServiceProvider = Provider<RecorderService>((ref) {
  final recorder = RecorderService();
  ref.onDispose(() => unawaited(recorder.dispose()));
  return recorder;
});

final sttServiceProvider = Provider<SttService>(
  (ref) => SttService(ref.watch(apiClientProvider)),
);

final ttsServiceProvider = Provider<TtsService>((ref) {
  final tts = TtsService();
  ref.onDispose(() => unawaited(tts.dispose()));
  return tts;
});

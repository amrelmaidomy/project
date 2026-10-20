import 'package:arabic_voice_reminder/core/app_exception.dart';
import 'package:arabic_voice_reminder/features/reminders/database/app_database.dart';
import 'package:arabic_voice_reminder/features/reminders/models/reminder.dart';
import 'package:arabic_voice_reminder/features/reminders/services/reminder_repository.dart';
import 'package:arabic_voice_reminder/features/reminders/services/reminder_scheduler.dart';
import 'package:arabic_voice_reminder/features/wake_word/background_reminders.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2030, 1, 1);
  late AppDatabase database;
  late RecordingScheduler scheduler;
  late BackgroundReminderWriter writer;

  Map<Object?, Object?> input() => {
    'confirmed': true,
    'expiresAt': now.add(const Duration(seconds: 40)).millisecondsSinceEpoch,
    'title': 'الدكتور',
    'event_datetime': '2030-01-02T17:00:00+02:00',
    'reminder_datetime': '2030-01-02T15:00:00+02:00',
    'missing_fields': <String>[],
    'ambiguous_fields': <String>[],
  };

  setUp(() {
    database = AppDatabase(NativeDatabase.memory());
    scheduler = RecordingScheduler();
    writer = BackgroundReminderWriter(
      ReminderRepository(
        database,
        BackgroundReminderScheduler(scheduler),
        now: () => now,
      ),
      now: () => now,
    );
  });
  tearDown(() => database.close());

  test(
    'confirmed background save persists and schedules the same reminder',
    () async {
      final result = await writer.save(input());
      final saved = (await database.allReminders()).single;
      expect(saved.id, result['id']);
      expect(saved.eventDateTime.toUtc(), DateTime.utc(2030, 1, 2, 15));
      expect(saved.reminderDateTime.toUtc(), DateTime.utc(2030, 1, 2, 13));
      expect(scheduler.scheduled!.id, saved.id);
      expect(scheduler.permissionRequests, [false]);
    },
  );

  test('no confirmation means no persisted or scheduled reminder', () async {
    await expectLater(
      writer.save(input()..['confirmed'] = false),
      throwsA(isA<AppException>()),
    );
    expect(await database.allReminders(), isEmpty);
    expect(scheduler.permissionRequests, isEmpty);
  });

  test('expired native requests cannot create a late reminder', () async {
    await expectLater(
      writer.save(input()..['expiresAt'] = now.millisecondsSinceEpoch),
      throwsA(isA<AppException>()),
    );
    expect(await database.allReminders(), isEmpty);
  });

  test(
    'ambiguous or incomplete parser output never reaches persistence',
    () async {
      for (final key in ['missing_fields', 'ambiguous_fields']) {
        await expectLater(
          writer.save(input()..[key] = ['time']),
          throwsA(isA<AppException>()),
        );
      }
      expect(await database.allReminders(), isEmpty);
    },
  );

  test('timestamps without offsets are rejected before saving', () async {
    await expectLater(
      writer.save(input()..['event_datetime'] = '2030-01-02T17:00:00'),
      throwsA(isA<AppException>()),
    );
    expect(await database.allReminders(), isEmpty);
  });

  test(
    'failed scheduling rolls back the background-created SQLite row',
    () async {
      scheduler.failSchedule = true;
      await expectLater(writer.save(input()), throwsStateError);
      expect(await database.allReminders(), isEmpty);
      expect(scheduler.cancelled, hasLength(1));
    },
  );

  test(
    'background permission denial never opens a prompt or writes data',
    () async {
      scheduler.denyPermission = true;
      await expectLater(writer.save(input()), throwsA(isA<AppException>()));
      expect(scheduler.permissionRequests, [false]);
      expect(await database.allReminders(), isEmpty);
    },
  );
}

class RecordingScheduler implements ReminderScheduler {
  final permissionRequests = <bool>[];
  final cancelled = <int>[];
  Reminder? scheduled;
  bool failSchedule = false;
  bool denyPermission = false;

  @override
  Future<void> ensureCanSchedule({bool requestPermissions = true}) async {
    permissionRequests.add(requestPermissions);
    if (denyPermission) throw const AppException('الإشعارات مقفولة.');
  }

  @override
  Future<void> schedule(Reminder reminder) async {
    if (failSchedule) throw StateError('Alarm rejected.');
    scheduled = reminder;
  }

  @override
  Future<void> cancel(int id) async {
    cancelled.add(id);
    scheduled = null;
  }
}

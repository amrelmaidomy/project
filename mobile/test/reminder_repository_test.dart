import 'dart:async';

import 'package:arabic_voice_reminder/core/app_exception.dart';
import 'package:arabic_voice_reminder/features/reminders/database/app_database.dart';
import 'package:arabic_voice_reminder/features/reminders/models/reminder.dart';
import 'package:arabic_voice_reminder/features/reminders/services/reminder_repository.dart';
import 'package:arabic_voice_reminder/features/reminders/services/reminder_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 10, 19, 12);
  late MemoryStore store;
  late FakeScheduler scheduler;
  late ReminderRepository repository;

  Reminder reminder({String title = 'الدكتور'}) => Reminder(
    title: title,
    eventDateTime: now.add(const Duration(hours: 2)),
    reminderDateTime: now.add(const Duration(hours: 1)),
    createdAt: now,
  );

  setUp(() {
    store = MemoryStore();
    scheduler = FakeScheduler();
    repository = ReminderRepository(store, scheduler, now: () => now);
  });

  test(
    'create persists trimmed title and schedules the same identifier',
    () async {
      final saved = await repository.create(reminder(title: '  الدكتور  '));
      expect(saved.id, 1);
      expect(saved.title, 'الدكتور');
      expect((await store.getReminder(1))?.title, 'الدكتور');
      expect(scheduler.scheduled[1]?.title, 'الدكتور');
    },
  );

  test('failed permission check never writes a reminder', () async {
    scheduler.permissionDenied = true;
    await expectLater(
      repository.create(reminder()),
      throwsA(isA<AppException>()),
    );
    expect(store.rows, isEmpty);
    expect(scheduler.scheduled, isEmpty);
  });

  test('schedule failure removes the new row and any partial alarm', () async {
    scheduler.failNextSchedule = true;
    await expectLater(repository.create(reminder()), throwsStateError);
    expect(store.rows, isEmpty);
    expect(scheduler.scheduled, isEmpty);
    expect(scheduler.cancelled, contains(1));
  });

  test(
    'failed create rollback reports uncertainty and retains the saved row',
    () async {
      scheduler.failNextSchedule = true;
      store.failNextDelete = true;
      await expectLater(
        repository.create(reminder()),
        throwsA(isA<ReminderConsistencyException>()),
      );
      expect(store.rows, hasLength(1));
      expect(scheduler.scheduled, isEmpty);
    },
  );

  test('rejects elapsed reminder time and reminders after the event', () async {
    await expectLater(
      repository.create(reminder().copyWith(reminderDateTime: now)),
      throwsA(isA<AppException>()),
    );
    await expectLater(
      repository.create(
        reminder().copyWith(
          reminderDateTime: now.add(const Duration(hours: 3)),
        ),
      ),
      throwsA(isA<AppException>()),
    );
    expect(store.rows, isEmpty);
  });

  test('failed edit restores the old SQLite row and alarm', () async {
    final saved = await repository.create(reminder());
    scheduler.failNextSchedule = true;
    await expectLater(
      repository.update(saved.copyWith(title: 'المكتب')),
      throwsStateError,
    );
    expect((await store.getReminder(saved.id!))?.title, 'الدكتور');
    expect(scheduler.scheduled[saved.id!]?.title, 'الدكتور');
  });

  test('complete cancels the alarm and preserves a completed row', () async {
    final saved = await repository.create(reminder());
    await repository.complete(saved.id!);
    expect((await store.getReminder(saved.id!))?.isCompleted, isTrue);
    expect(scheduler.scheduled, isEmpty);
  });

  test('failed completion restores the active alarm', () async {
    final saved = await repository.create(reminder());
    store.failNextReplace = true;
    await expectLater(repository.complete(saved.id!), throwsStateError);
    expect((await store.getReminder(saved.id!))?.isCompleted, isFalse);
    expect(scheduler.scheduled, contains(saved.id!));
  });

  test('failed storage and alarm restoration reports uncertainty', () async {
    final saved = await repository.create(reminder());
    store.failNextReplace = true;
    scheduler.failNextSchedule = true;
    await expectLater(
      repository.complete(saved.id!),
      throwsA(isA<ReminderConsistencyException>()),
    );
    expect((await store.getReminder(saved.id!))?.isCompleted, isFalse);
  });

  test('failed delete restores alarm and retains row', () async {
    final saved = await repository.create(reminder());
    store.failNextDelete = true;
    await expectLater(repository.delete(saved.id!), throwsStateError);
    expect(await store.getReminder(saved.id!), isNotNull);
    expect(scheduler.scheduled, contains(saved.id!));
  });

  test('delete removes the SQLite row and its alarm', () async {
    final saved = await repository.create(reminder());
    await repository.delete(saved.id!);
    expect(await store.getReminder(saved.id!), isNull);
    expect(scheduler.scheduled, isEmpty);
  });

  test(
    'startup schedules future active rows and cancels elapsed/completed',
    () async {
      final activeId = await store.insertReminder(reminder());
      final elapsedId = await store.insertReminder(
        reminder().copyWith(
          reminderDateTime: now.subtract(const Duration(minutes: 1)),
        ),
      );
      final completedId = await store.insertReminder(
        reminder().copyWith(status: ReminderStatus.completed),
      );
      await repository.rescheduleFuture();
      expect(scheduler.scheduled.keys, [activeId]);
      expect(scheduler.cancelled, containsAll([elapsedId, completedId]));
      expect(scheduler.permissionChecks, 0);
    },
  );

  test(
    'failed operation does not poison subsequent serialized operations',
    () async {
      scheduler.failNextSchedule = true;
      final first = repository.create(reminder());
      final failed = expectLater(first, throwsStateError);
      final second = repository.create(reminder(title: 'الشغل'));
      await failed;
      final saved = await second;
      expect(store.rows.values.single.title, 'الشغل');
      expect(scheduler.scheduled.keys, [saved.id]);
    },
  );
}

class MemoryStore implements ReminderStore {
  final rows = <int, Reminder>{};
  var _nextId = 1;
  bool failNextReplace = false;
  bool failNextDelete = false;

  @override
  Future<List<Reminder>> allReminders() async => rows.values.toList();
  @override
  Future<Reminder?> getReminder(int id) async => rows[id];
  @override
  Future<int> insertReminder(Reminder reminder) async {
    final id = _nextId++;
    rows[id] = reminder.copyWith(id: id);
    return id;
  }

  @override
  Future<void> replaceReminder(Reminder reminder) async {
    if (failNextReplace) {
      failNextReplace = false;
      throw StateError('Database write failed.');
    }
    rows[reminder.id!] = reminder;
  }

  @override
  Future<void> deleteReminder(int id) async {
    if (failNextDelete) {
      failNextDelete = false;
      throw StateError('Database delete failed.');
    }
    rows.remove(id);
  }

  @override
  Stream<List<Reminder>> watchReminders() => Stream.value(rows.values.toList());
}

class FakeScheduler implements ReminderScheduler {
  final scheduled = <int, Reminder>{};
  final cancelled = <int>[];
  var permissionChecks = 0;
  bool permissionDenied = false;
  bool failNextSchedule = false;

  @override
  Future<void> ensureCanSchedule({bool requestPermissions = true}) async {
    permissionChecks++;
    if (permissionDenied) throw const AppException('Notifications disabled.');
  }

  @override
  Future<void> schedule(Reminder reminder) async {
    scheduled[reminder.id!] = reminder;
    if (failNextSchedule) {
      failNextSchedule = false;
      throw StateError('Platform failed after scheduling.');
    }
  }

  @override
  Future<void> cancel(int id) async {
    cancelled.add(id);
    scheduled.remove(id);
  }
}

import 'dart:io';

import 'package:arabic_voice_reminder/features/reminders/database/app_database.dart';
import 'package:arabic_voice_reminder/features/reminders/models/reminder.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Reminder reminder() => Reminder(
    title: 'ميعاد الدكتور',
    eventDateTime: DateTime.parse('2026-10-20T17:00:00+03:00'),
    reminderDateTime: DateTime.parse('2026-10-20T16:30:00+03:00'),
    createdAt: DateTime.parse('2026-10-19T12:00:00Z'),
  );

  test(
    'SQLite round-trips instants without losing the original offset',
    () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final input = reminder();
      final id = await database.insertReminder(input);
      final actual = (await database.getReminder(id))!;
      expect(actual.id, id);
      expect(actual.title, input.title);
      expect(
        actual.eventDateTime.isAtSameMomentAs(input.eventDateTime),
        isTrue,
      );
      expect(
        actual.reminderDateTime.isAtSameMomentAs(input.reminderDateTime),
        isTrue,
      );
      expect(actual.createdAt.isAtSameMomentAs(input.createdAt), isTrue);
    },
  );

  test('SQLite updates and deletes notify live reminder subscribers', () async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final stream = database.watchReminders().asBroadcastStream();
    final empty = stream.first;
    expect(await empty, isEmpty);
    final inserted = stream.first;
    final id = await database.insertReminder(reminder());
    expect((await inserted).single.id, id);
    final updated = stream.first;
    await database.replaceReminder(
      reminder().copyWith(id: id, status: ReminderStatus.completed),
    );
    expect((await updated).single.isCompleted, isTrue);
    final deleted = stream.first;
    await database.deleteReminder(id);
    expect(await deleted, isEmpty);
  });

  test('saved reminders survive closing and reopening the database', () async {
    final directory = await Directory.systemTemp.createTemp(
      'fakkarni_db_test_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/reminders.sqlite');
    final original = AppDatabase(NativeDatabase(file));
    final id = await original.insertReminder(reminder());
    await original.close();
    final reopened = AppDatabase(NativeDatabase(file));
    addTearDown(reopened.close);
    expect((await reopened.getReminder(id))?.title, 'ميعاد الدكتور');
  });
}

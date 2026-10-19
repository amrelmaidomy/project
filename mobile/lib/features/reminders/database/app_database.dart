import 'dart:async';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import '../models/reminder.dart';

abstract interface class ReminderStore {
  Future<List<Reminder>> allReminders();
  Stream<List<Reminder>> watchReminders();
  Future<Reminder?> getReminder(int id);
  Future<int> insertReminder(Reminder reminder);
  Future<void> replaceReminder(Reminder reminder);
  Future<void> deleteReminder(int id);
}

/// Drift owns SQLite connections and migration transactions. The small explicit
/// schema avoids generated files and keeps a fresh checkout directly runnable.
class AppDatabase extends GeneratedDatabase implements ReminderStore {
  AppDatabase([QueryExecutor? executor])
    : super(executor ?? driftDatabase(name: 'fakkarni'));

  final _changes = StreamController<void>.broadcast();

  @override
  int get schemaVersion => 1;

  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];

  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => const [];

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (_) async {
      await customStatement('''
      CREATE TABLE reminders (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL CHECK(length(trim(title)) > 0),
        event_at INTEGER NOT NULL,
        remind_at INTEGER NOT NULL,
        created_at INTEGER NOT NULL,
        status TEXT NOT NULL DEFAULT 'active'
          CHECK(status IN ('active', 'completed'))
      )
    ''');
      await customStatement(
        'CREATE INDEX reminders_schedule ON reminders(status, remind_at)',
      );
    },
  );

  Reminder _read(QueryRow row) => Reminder(
    id: row.read<int>('id'),
    title: row.read<String>('title'),
    eventDateTime: DateTime.fromMillisecondsSinceEpoch(
      row.read<int>('event_at'),
      isUtc: true,
    ).toLocal(),
    reminderDateTime: DateTime.fromMillisecondsSinceEpoch(
      row.read<int>('remind_at'),
      isUtc: true,
    ).toLocal(),
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      row.read<int>('created_at'),
      isUtc: true,
    ).toLocal(),
    status: ReminderStatus.values.byName(row.read<String>('status')),
  );

  @override
  Future<List<Reminder>> allReminders() async {
    final rows = await customSelect('''
      SELECT * FROM reminders
      ORDER BY CASE status WHEN 'active' THEN 0 ELSE 1 END, event_at, id
    ''').get();
    return rows.map(_read).toList(growable: false);
  }

  @override
  Stream<List<Reminder>> watchReminders() {
    late final StreamController<List<Reminder>> controller;
    StreamSubscription<void>? subscription;
    var cancelled = false;
    var pending = Future<void>.value();
    void refresh() {
      pending = pending.then((_) async {
        if (cancelled) return;
        try {
          final reminders = await allReminders();
          if (!cancelled) controller.add(reminders);
        } catch (error, stack) {
          if (!cancelled) controller.addError(error, stack);
        }
      });
    }

    controller = StreamController<List<Reminder>>(
      onListen: () {
        // Subscribe before reading so an insert cannot be lost between them.
        subscription = _changes.stream.listen(
          (_) => refresh(),
          onDone: () => controller.close(),
        );
        refresh();
      },
      onCancel: () async {
        cancelled = true;
        await subscription?.cancel();
      },
    );
    return controller.stream;
  }

  @override
  Future<Reminder?> getReminder(int id) async {
    final row = await customSelect(
      'SELECT * FROM reminders WHERE id = ?',
      variables: [Variable<int>(id)],
    ).getSingleOrNull();
    return row == null ? null : _read(row);
  }

  List<Variable<Object>> _values(Reminder reminder) => [
    Variable<String>(reminder.title),
    Variable<int>(reminder.eventDateTime.toUtc().millisecondsSinceEpoch),
    Variable<int>(reminder.reminderDateTime.toUtc().millisecondsSinceEpoch),
    Variable<int>(reminder.createdAt.toUtc().millisecondsSinceEpoch),
    Variable<String>(reminder.status.name),
  ];

  @override
  Future<int> insertReminder(Reminder reminder) async {
    final id = await customInsert('''
      INSERT INTO reminders(title, event_at, remind_at, created_at, status)
      VALUES (?, ?, ?, ?, ?)
    ''', variables: _values(reminder));
    _changes.add(null);
    return id;
  }

  @override
  Future<void> replaceReminder(Reminder reminder) async {
    if (reminder.id == null) {
      throw ArgumentError('A saved reminder needs an id.');
    }
    final changed = await customUpdate(
      '''
      UPDATE reminders SET title = ?, event_at = ?, remind_at = ?,
        created_at = ?, status = ? WHERE id = ?
    ''',
      variables: [..._values(reminder), Variable<int>(reminder.id!)],
    );
    if (changed != 1) throw StateError('Reminder does not exist.');
    _changes.add(null);
  }

  @override
  Future<void> deleteReminder(int id) async {
    await customUpdate(
      'DELETE FROM reminders WHERE id = ?',
      variables: [Variable<int>(id)],
    );
    _changes.add(null);
  }

  @override
  Future<void> close() async {
    await _changes.close();
    await super.close();
  }
}

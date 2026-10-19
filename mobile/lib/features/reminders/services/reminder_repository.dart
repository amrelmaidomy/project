import 'dart:async';

import '../../../core/app_exception.dart';
import '../database/app_database.dart';
import '../models/reminder.dart';
import 'reminder_scheduler.dart';

/// Coordinates local persistence and Android alarms. Platform alarms cannot join
/// a SQLite transaction, so failures restore the previous database/alarm state.
class ReminderRepository {
  ReminderRepository(this._store, this._scheduler, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final ReminderStore _store;
  final ReminderScheduler _scheduler;
  final DateTime Function() _now;
  Future<void> _pending = Future<void>.value();

  Stream<List<Reminder>> watchAll() => _store.watchReminders();
  Future<List<Reminder>> getAll() => _store.allReminders();
  Future<Reminder?> getById(int id) => _store.getReminder(id);

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final result = Completer<T>();
    _pending = _pending.then((_) async {
      try {
        result.complete(await operation());
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  Reminder _validate(Reminder reminder) {
    final title = reminder.title.trim();
    if (title.isEmpty) throw const AppException('اكتب عنوان للتذكير.');
    if (title.length > 200) {
      throw const AppException('عنوان التذكير لازم يكون أقل من ٢٠٠ حرف.');
    }
    if (!reminder.isCompleted && !reminder.reminderDateTime.isAfter(_now())) {
      throw const AppException('وقت التذكير لازم يكون في المستقبل.');
    }
    if (reminder.reminderDateTime.isAfter(reminder.eventDateTime)) {
      throw const AppException('وقت التذكير لازم يكون قبل الميعاد أو معاه.');
    }
    return reminder.copyWith(title: title);
  }

  Future<Reminder> save(Reminder reminder) =>
      reminder.id == null ? create(reminder) : update(reminder);

  Future<Reminder> create(Reminder reminder) => _serialized(() async {
    if (reminder.id != null) throw ArgumentError('Reminder is already saved.');
    final valid = _validate(reminder);
    if (!valid.isCompleted) await _scheduler.ensureCanSchedule();
    final id = await _store.insertReminder(valid);
    final saved = valid.copyWith(id: id);
    try {
      if (!saved.isCompleted) await _scheduler.schedule(saved);
    } catch (error, stack) {
      try {
        // A platform error may occur after an alarm was created.
        await _scheduler.cancel(id);
        await _store.deleteReminder(id);
      } catch (_) {
        throw const ReminderConsistencyException(
          'حصل خطأ أثناء حفظ التذكير وإلغاء التنبيه. راجع قائمة التذكيرات قبل المحاولة تاني.',
        );
      }
      Error.throwWithStackTrace(error, stack);
    }
    return saved;
  });

  Future<Reminder> update(Reminder reminder) => _serialized(() async {
    if (reminder.id == null) {
      throw ArgumentError('Reminder has not been saved.');
    }
    final old = await _require(reminder.id!);
    final valid = _validate(reminder.copyWith(createdAt: old.createdAt));
    if (!valid.isCompleted) await _scheduler.ensureCanSchedule();
    await _store.replaceReminder(valid);
    try {
      await _applySchedule(valid);
    } catch (error, stack) {
      try {
        await _store.replaceReminder(old);
        await _applySchedule(old);
      } catch (_) {
        throw const ReminderConsistencyException(
          'تعذّر استرجاع حالة التنبيه بعد فشل التعديل. راجع التذكير وافتح التطبيق تاني.',
        );
      }
      Error.throwWithStackTrace(error, stack);
    }
    return valid;
  });

  Future<void> complete(int id) => _serialized(() async {
    final old = await _require(id);
    if (old.isCompleted) return;
    await _scheduler.cancel(id);
    try {
      await _store.replaceReminder(
        old.copyWith(status: ReminderStatus.completed),
      );
    } catch (error, stack) {
      await _restoreAfterStorageFailure(old);
      Error.throwWithStackTrace(error, stack);
    }
  });

  Future<void> delete(int id) => _serialized(() async {
    final old = await _require(id);
    await _scheduler.cancel(id);
    try {
      await _store.deleteReminder(id);
    } catch (error, stack) {
      await _restoreAfterStorageFailure(old);
      Error.throwWithStackTrace(error, stack);
    }
  });

  Future<void> _restoreAfterStorageFailure(Reminder old) async {
    try {
      await _applySchedule(old);
    } catch (_) {
      throw const ReminderConsistencyException(
        'حصل خطأ في الحفظ واسترجاع التنبيه. التذكير موجود؛ راجع إذن التنبيهات وافتح التطبيق تاني.',
      );
    }
  }

  Future<Reminder> _require(int id) async {
    final reminder = await _store.getReminder(id);
    if (reminder == null) throw const AppException('التذكير ده مش موجود.');
    return reminder;
  }

  Future<void> _applySchedule(Reminder reminder) async {
    if (!reminder.isCompleted && reminder.reminderDateTime.isAfter(_now())) {
      await _scheduler.schedule(reminder);
    } else {
      await _scheduler.cancel(reminder.id!);
    }
  }

  /// Startup reconciliation never requests permissions. Android's boot receiver
  /// restores saved alarms after reboot; this also repairs interrupted writes.
  Future<void> rescheduleFuture() => _serialized(() async {
    final reminders = await _store.allReminders();
    Object? firstError;
    StackTrace? firstStack;
    for (final reminder in reminders) {
      try {
        await _applySchedule(reminder);
      } catch (error, stack) {
        firstError ??= error;
        firstStack ??= stack;
      }
    }
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStack!);
    }
  });
}

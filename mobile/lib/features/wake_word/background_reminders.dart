import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../core/app_exception.dart';
import '../reminders/database/app_database.dart';
import '../reminders/models/reminder.dart';
import '../reminders/services/notification_service.dart';
import '../reminders/services/reminder_repository.dart';
import '../reminders/services/reminder_scheduler.dart';

/// Uses the same persistence, alarm validation and rollback as the visible UI.
/// The native conversation invokes this only after an explicit spoken confirm.
class BackgroundReminderWriter {
  BackgroundReminderWriter(this._repository, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final ReminderRepository _repository;
  final DateTime Function() _now;

  Future<Map<String, Object>> save(Map<Object?, Object?> input) async {
    if (input['confirmed'] != true) {
      throw const AppException('لازم تأكيد صريح قبل حفظ الموعد.');
    }
    final expiresAt = input['expiresAt'];
    if (expiresAt is! int || expiresAt <= _now().millisecondsSinceEpoch) {
      throw const AppException(
        'انتهت مهلة الحفظ. راجع مواعيدك قبل المحاولة تاني.',
      );
    }
    for (final key in ['missing_fields', 'ambiguous_fields']) {
      final fields = input[key];
      if (fields is! List || fields.isNotEmpty) {
        throw const AppException('تفاصيل الموعد لسه ناقصة أو محتاجة توضيح.');
      }
    }
    DateTime instant(String key) {
      final value = input[key];
      if (value is! String ||
          !RegExp(r'(?:Z|[+-]\d{2}:\d{2})$').hasMatch(value)) {
        throw const AppException('وقت الموعد لازم يشمل المنطقة الزمنية.');
      }
      final parsed = DateTime.tryParse(value);
      if (parsed == null) throw const AppException('وقت الموعد غير صالح.');
      return parsed;
    }

    final title = input['title'];
    if (title is! String || title.trim().isEmpty) {
      throw const AppException('عنوان التذكير مش موجود.');
    }
    final saved = await _repository.create(
      Reminder(
        title: title,
        eventDateTime: instant('event_datetime'),
        reminderDateTime: instant('reminder_datetime'),
      ),
    );
    return {'id': saved.id!};
  }
}

/// Background work must never try to open an Android permission Activity.
class BackgroundReminderScheduler implements ReminderScheduler {
  BackgroundReminderScheduler(this._delegate);

  final ReminderScheduler _delegate;

  @override
  Future<void> ensureCanSchedule({bool requestPermissions = true}) =>
      _delegate.ensureCanSchedule(requestPermissions: false);

  @override
  Future<void> schedule(Reminder reminder) => _delegate.schedule(reminder);

  @override
  Future<void> cancel(int id) => _delegate.cancel(id);
}

/// Runs in a temporary native-owned engine; no Activity or visible UI is needed.
void startRafiqBackground() {
  WidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.ma3ak.reminder/rafiq_background');
  final database = AppDatabase();
  final writer = BackgroundReminderWriter(
    ReminderRepository(
      database,
      BackgroundReminderScheduler(NotificationService()),
    ),
  );
  var pending = Future<void>.value();
  var closing = false;
  channel.setMethodCallHandler((call) {
    final complete = Completer<Object?>();
    // Serializing shutdown behind an in-flight save preserves DB/alarm rollback.
    pending = pending.then((_) async {
      try {
        switch (call.method) {
          case 'save':
            if (closing) throw StateError('The background writer is closed.');
            final input = call.arguments;
            if (input is! Map) {
              throw const FormatException('Invalid background reminder.');
            }
            complete.complete(
              await writer.save(Map<Object?, Object?>.from(input)),
            );
          case 'shutdown':
            closing = true;
            await database.close();
            complete.complete(null);
          default:
            throw MissingPluginException(
              'Unknown background reminder operation.',
            );
        }
      } catch (error) {
        complete.completeError(
          PlatformException(
            code: 'background_reminder',
            message: error.toString(),
          ),
        );
      }
    });
    return complete.future;
  });
  unawaited(channel.invokeMethod<void>('ready'));
}

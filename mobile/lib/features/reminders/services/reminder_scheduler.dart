import '../models/reminder.dart';

abstract interface class ReminderScheduler {
  Future<void> ensureCanSchedule({bool requestPermissions = true});
  Future<void> schedule(Reminder reminder);
  Future<void> cancel(int id);
}

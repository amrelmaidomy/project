import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:intl/intl.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../../../core/app_exception.dart';
import '../models/reminder.dart';
import 'reminder_scheduler.dart';

class NotificationService implements ReminderScheduler {
  NotificationService({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  Future<void>? _initialization;

  Future<void> initialize() async {
    // A failed initialization is retryable after a platform/permission change.
    try {
      await (_initialization ??= _initialize());
    } catch (_) {
      _initialization = null;
      rethrow;
    }
  }

  Future<void> _initialize() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      throw const AppException('التنبيهات الدقيقة متاحة في نسخة أندرويد.');
    }
    tzdata.initializeTimeZones();
    final timezone = await FlutterTimezone.getLocalTimezone();
    tz.setLocalLocation(tz.getLocation(timezone));
    final initialized = await _plugin.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@drawable/ic_notification'),
      ),
    );
    if (initialized != true) {
      throw const AppException('تعذّر تشغيل خدمة التنبيهات. حاول مرة تانية.');
    }
    await _android.createNotificationChannel(
      const AndroidNotificationChannel(
        'reminders',
        'تذكيرات معاك',
        description: 'تنبيهات مواعيدك وتذكيراتك',
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
      ),
    );
  }

  AndroidFlutterLocalNotificationsPlugin get _android {
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android == null) {
      throw const AppException('خدمة التنبيهات مش متاحة على الجهاز ده.');
    }
    return android;
  }

  @override
  Future<void> ensureCanSchedule({bool requestPermissions = true}) async {
    await initialize();
    var notifications = await _android.areNotificationsEnabled() == true;
    if (!notifications && requestPermissions) {
      await _android.requestNotificationsPermission();
      notifications = await _android.areNotificationsEnabled() == true;
    }
    if (!notifications) {
      throw const AppException(
        'فعّل إذن الإشعارات لمعَاك من إعدادات الجهاز، وبعدها احفظ التذكير.',
      );
    }
    final channels = await _android.getNotificationChannels();
    if (channels?.any(
          (channel) =>
              channel.id == 'reminders' &&
              channel.importance == Importance.none,
        ) ==
        true) {
      throw const AppException(
        'فعّل قناة «تذكيرات معاك» من إعدادات إشعارات التطبيق عشان التنبيه يوصلك.',
      );
    }
    var exact = await _android.canScheduleExactNotifications() == true;
    if (!exact && requestPermissions) {
      await _android.requestExactAlarmsPermission();
      exact = await _android.canScheduleExactNotifications() == true;
    }
    if (!exact) {
      throw const AppException(
        'فعّل «المنبّهات والتذكيرات» لمعَاك عشان التذكير يوصلك في معاده.',
      );
    }
  }

  @override
  Future<void> schedule(Reminder reminder) async {
    if (reminder.id == null || reminder.id! <= 0 || reminder.id! > 2147483647) {
      throw ArgumentError('A reminder needs a valid Android notification id.');
    }
    if (reminder.isCompleted ||
        !reminder.reminderDateTime.isAfter(DateTime.now())) {
      throw const AppException('وقت التذكير لازم يكون في المستقبل.');
    }
    // Never report success when Android silently drops a disabled notification.
    await ensureCanSchedule(requestPermissions: false);
    await _plugin.zonedSchedule(
      reminder.id!,
      reminder.title,
      'ميعادك الساعة ${DateFormat('HH:mm').format(reminder.eventDateTime.toLocal())}',
      tz.TZDateTime.from(reminder.reminderDateTime, tz.local),
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'reminders',
          'تذكيرات معاك',
          channelDescription: 'تنبيهات مواعيدك وتذكيراتك',
          importance: Importance.max,
          priority: Priority.high,
          category: AndroidNotificationCategory.reminder,
          visibility: NotificationVisibility.private,
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      payload: 'reminder:${reminder.id}',
    );
  }

  @override
  Future<void> cancel(int id) async {
    await initialize();
    await _plugin.cancel(id);
  }
}

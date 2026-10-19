enum ReminderStatus { active, completed }

/// A single local reminder. Dates are instants; storage converts them to UTC.
class Reminder {
  Reminder({
    this.id,
    required this.title,
    required this.eventDateTime,
    required this.reminderDateTime,
    DateTime? createdAt,
    this.status = ReminderStatus.active,
  }) : createdAt = createdAt ?? DateTime.now();

  final int? id;
  final String title;
  final DateTime eventDateTime;
  final DateTime reminderDateTime;
  final DateTime createdAt;
  final ReminderStatus status;

  bool get isCompleted => status == ReminderStatus.completed;

  Reminder copyWith({
    int? id,
    String? title,
    DateTime? eventDateTime,
    DateTime? reminderDateTime,
    DateTime? createdAt,
    ReminderStatus? status,
  }) => Reminder(
    id: id ?? this.id,
    title: title ?? this.title,
    eventDateTime: eventDateTime ?? this.eventDateTime,
    reminderDateTime: reminderDateTime ?? this.reminderDateTime,
    createdAt: createdAt ?? this.createdAt,
    status: status ?? this.status,
  );
}

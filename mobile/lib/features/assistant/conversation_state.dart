enum AssistantPhase {
  idle,
  preparing,
  recording,
  transcribing,
  parsing,
  awaitingDetails,
  awaitingConfirmation,
  saving,
  error,
}

class ConversationMessage {
  const ConversationMessage({required this.text, required this.isUser});

  final String text;
  final bool isUser;
}

/// The slots belong to the current conversation, never to a global parser.
class ReminderDraft {
  const ReminderDraft({
    this.title,
    this.date,
    this.time,
    this.remindBeforeMinutes,
    this.eventDateTime,
    this.reminderDateTime,
    this.missingFields = const [],
    this.ambiguousFields = const [],
    this.question,
    this.timezone = 'Africa/Cairo',
    this.timezoneFallback = false,
  });

  final String? title;
  final String? date;
  final String? time;
  final int? remindBeforeMinutes;
  final DateTime? eventDateTime;
  final DateTime? reminderDateTime;
  final List<String> missingFields;
  final List<String> ambiguousFields;
  final String? question;
  final String timezone;
  final bool timezoneFallback;

  bool get isComplete =>
      title != null &&
      title!.trim().isNotEmpty &&
      date != null &&
      time != null &&
      remindBeforeMinutes != null &&
      remindBeforeMinutes! >= 0 &&
      eventDateTime != null &&
      reminderDateTime != null &&
      missingFields.isEmpty &&
      ambiguousFields.isEmpty;

  Map<String, Object?> get context => {
    if (title != null) 'title': title,
    if (date != null) 'date': date,
    if (time != null) 'time': time,
    if (remindBeforeMinutes != null)
      'remind_before_minutes': remindBeforeMinutes,
  };

  factory ReminderDraft.fromJson(
    Map<String, dynamic> json, {
    String timezone = 'Africa/Cairo',
    bool timezoneFallback = false,
  }) {
    String? nonEmpty(Object? value) {
      if (value is! String || value.trim().isEmpty) return null;
      return value.trim();
    }

    DateTime? timestamp(Object? value) {
      if (value is! String) return null;
      // The backend must include an offset. A device-local guess is unsafe.
      if (!RegExp(r'(Z|[+-]\d{2}:\d{2})$').hasMatch(value)) return null;
      return DateTime.tryParse(value);
    }

    List<String> fields(Object? value) => value is List
        ? List<String>.unmodifiable(value.whereType<String>())
        : const [];

    return ReminderDraft(
      title: nonEmpty(json['title']),
      date: nonEmpty(json['date']),
      time: nonEmpty(json['time']),
      remindBeforeMinutes: (json['remind_before_minutes'] as num?)?.toInt(),
      eventDateTime: timestamp(json['event_datetime']),
      reminderDateTime: timestamp(json['reminder_datetime']),
      missingFields: fields(json['missing_fields']),
      ambiguousFields: fields(json['ambiguous_fields']),
      question: nonEmpty(json['question']),
      timezone: timezone,
      timezoneFallback: timezoneFallback,
    );
  }
}

class ConversationState {
  const ConversationState({
    this.phase = AssistantPhase.idle,
    this.draft = const ReminderDraft(),
    this.messages = const [],
    this.latestTranscript,
    this.error,
    this.microphoneActive = false,
    this.recordingStartedAt,
    this.lastSubmittedText,
    this.saveUncertain = false,
  });

  final AssistantPhase phase;
  final ReminderDraft draft;
  final List<ConversationMessage> messages;
  final String? latestTranscript;
  final String? error;
  final bool microphoneActive;
  final DateTime? recordingStartedAt;
  final String? lastSubmittedText;
  final bool saveUncertain;

  bool get isBusy => const {
    AssistantPhase.preparing,
    AssistantPhase.recording,
    AssistantPhase.transcribing,
    AssistantPhase.parsing,
    AssistantPhase.saving,
  }.contains(phase);

  ConversationState copyWith({
    AssistantPhase? phase,
    ReminderDraft? draft,
    List<ConversationMessage>? messages,
    String? latestTranscript,
    bool clearTranscript = false,
    String? error,
    bool clearError = false,
    bool? microphoneActive,
    DateTime? recordingStartedAt,
    bool clearRecordingStartedAt = false,
    String? lastSubmittedText,
    bool clearLastSubmittedText = false,
    bool? saveUncertain,
  }) => ConversationState(
    phase: phase ?? this.phase,
    draft: draft ?? this.draft,
    messages: messages ?? this.messages,
    latestTranscript: clearTranscript
        ? null
        : latestTranscript ?? this.latestTranscript,
    error: clearError ? null : error ?? this.error,
    microphoneActive: microphoneActive ?? this.microphoneActive,
    recordingStartedAt: clearRecordingStartedAt
        ? null
        : recordingStartedAt ?? this.recordingStartedAt,
    lastSubmittedText: clearLastSubmittedText
        ? null
        : lastSubmittedText ?? this.lastSubmittedText,
    saveUncertain: saveUncertain ?? this.saveUncertain,
  );
}

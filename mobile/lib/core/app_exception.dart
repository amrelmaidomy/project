class AppException implements Exception {
  const AppException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Persistence or alarm rollback failed; retrying a create may duplicate data.
class ReminderConsistencyException extends AppException {
  const ReminderConsistencyException(super.message);
}

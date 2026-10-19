import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/app_exception.dart';
import '../../../core/providers.dart';
import '../models/reminder.dart';

class ReminderForm extends ConsumerStatefulWidget {
  const ReminderForm({super.key, this.reminder});
  final Reminder? reminder;

  @override
  ConsumerState<ReminderForm> createState() => _ReminderFormState();
}

class _ReminderFormState extends ConsumerState<ReminderForm> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _title;
  late DateTime _date;
  late TimeOfDay _time;
  late int _offset;
  bool _busy = false;
  bool _uncertain = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final next =
        widget.reminder?.eventDateTime.toLocal() ??
        DateTime.now().add(const Duration(days: 1));
    _title = TextEditingController(text: widget.reminder?.title);
    _date = DateTime(next.year, next.month, next.day);
    _time = TimeOfDay.fromDateTime(next);
    _offset = widget.reminder == null
        ? 120
        : widget.reminder!.eventDateTime
              .difference(widget.reminder!.reminderDateTime)
              .inMinutes;
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  DateTime get _event =>
      DateTime(_date.year, _date.month, _date.day, _time.hour, _time.minute);

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final event = _event;
    final reminderTime = event.subtract(Duration(minutes: _offset));
    if (!reminderTime.isAfter(DateTime.now())) {
      setState(
        () => _error = 'وقت التنبيه فات. اختار موعدًا أو مدة تذكير مناسبة.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final reminder = Reminder(
        id: widget.reminder?.id,
        title: _title.text.trim(),
        eventDateTime: event,
        reminderDateTime: reminderTime,
        createdAt: widget.reminder?.createdAt,
      );
      await ref.read(reminderRepositoryProvider).save(reminder);
      if (!mounted) return;
      final tts = ref.read(ttsServiceProvider);
      Navigator.of(context).pop(true);
      // Speech is optional feedback; a missing Arabic device voice must not undo a save.
      try {
        await tts.speak('تمام، سجلت التذكير');
      } catch (_) {}
    } catch (error) {
      if (mounted) {
        setState(() {
          _uncertain = error is ReminderConsistencyException;
          _error = error is AppException
              ? error.message
              : 'تعذّر حفظ التذكير. راجع قائمة التذكيرات قبل المحاولة مرة تانية.';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final offsets = <int>{0, 15, 30, 60, 120, 1440, _offset}.toList()..sort();
    final now = DateTime.now();
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.reminder == null ? 'إضافة تذكير' : 'تعديل التذكير'),
      ),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text(
              'خلّي بالك من يومك، وسيب التذكير علينا.',
              style: TextStyle(fontSize: 17, color: Color(0xff69766e)),
            ),
            const SizedBox(height: 30),
            TextFormField(
              controller: _title,
              enabled: !_busy,
              maxLength: 120,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                labelText: 'اسم الحدث',
                hintText: 'مثلاً: مناقشة مشروع التخرج',
                prefixIcon: Icon(Icons.edit_note_rounded),
              ),
              validator: (value) =>
                  (value?.trim().isEmpty ?? true) ? 'اكتب اسم الحدث' : null,
            ),
            const SizedBox(height: 20),
            _PickerTile(
              label: 'التاريخ',
              value: DateFormat('EEEE، d MMMM y', 'ar_EG').format(_date),
              icon: Icons.calendar_today_outlined,
              onTap: _busy
                  ? null
                  : () async {
                      final first = DateTime(now.year, now.month, now.day);
                      final value = await showDatePicker(
                        context: context,
                        initialDate: _date.isBefore(first) ? first : _date,
                        firstDate: first,
                        lastDate: DateTime(now.year + 10),
                      );
                      if (value != null && mounted) {
                        setState(() => _date = value);
                      }
                    },
            ),
            const SizedBox(height: 12),
            _PickerTile(
              label: 'الساعة',
              value: _time.format(context),
              icon: Icons.schedule,
              onTap: _busy
                  ? null
                  : () async {
                      final value = await showTimePicker(
                        context: context,
                        initialTime: _time,
                      );
                      if (value != null && mounted) {
                        setState(() => _time = value);
                      }
                    },
            ),
            const SizedBox(height: 26),
            const Text(
              'فكّرني قبلها',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: offsets
                  .map(
                    (minutes) => ChoiceChip(
                      label: Text(offsetLabel(minutes)),
                      selected: minutes == _offset,
                      onSelected: _busy
                          ? null
                          : (_) => setState(() => _offset = minutes),
                    ),
                  )
                  .toList(),
            ),
            const SizedBox(height: 26),
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: const Color(0xffe5eee4),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.notifications_active_outlined,
                    color: Color(0xff21645c),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'هنفكّرك ${DateFormat('EEEE d MMMM، h:mm a', 'ar_EG').format(_event.subtract(Duration(minutes: _offset)))}',
                    ),
                  ),
                ],
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 28),
            FilledButton.icon(
              onPressed: _busy || _uncertain ? null : _save,
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check_rounded),
              label: Text(_busy ? 'بنحفظ التذكير…' : 'حفظ التذكير'),
            ),
          ],
        ),
      ),
    );
  }
}

String offsetLabel(int minutes) => switch (minutes) {
  0 => 'في الموعد',
  15 => 'ربع ساعة',
  30 => 'نصف ساعة',
  60 => 'ساعة',
  120 => 'ساعتين',
  1440 => 'يوم',
  _ => '$minutes دقيقة',
};

class _PickerTile extends StatelessWidget {
  const _PickerTile({
    required this.label,
    required this.value,
    required this.icon,
    this.onTap,
  });
  final String label;
  final String value;
  final IconData icon;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    borderRadius: BorderRadius.circular(16),
    child: ListTile(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      leading: Icon(icon),
      title: Text(label),
      subtitle: Text(value),
      trailing: const Icon(Icons.expand_more),
      onTap: onTap,
    ),
  );
}

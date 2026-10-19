import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/providers.dart';
import '../models/reminder.dart';
import 'reminder_form.dart';

class RemindersScreen extends ConsumerStatefulWidget {
  const RemindersScreen({super.key, required this.onOpenAssistant});
  final VoidCallback onOpenAssistant;
  @override
  ConsumerState<RemindersScreen> createState() => _RemindersScreenState();
}

class _RemindersScreenState extends ConsumerState<RemindersScreen> {
  bool _showCompleted = false;

  Future<void> _openForm([Reminder? reminder]) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => ReminderForm(reminder: reminder)),
    );
    if (saved == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('اتحفظ التذكير واتحدد وقت التنبيه ✓')),
      );
    }
  }

  Future<void> _act(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تعذّر تنفيذ العملية. حاول مرة تانية.')),
        );
      }
    }
  }

  Future<void> _delete(Reminder reminder) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('حذف التذكير؟'),
        content: Text('هيتم حذف «${reminder.title}» وإلغاء التنبيه الخاص به.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('رجوع'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await _act(
        () => ref.read(reminderRepositoryProvider).delete(reminder.id!),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final reminders = ref.watch(remindersProvider);
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 88,
        title: const Row(
          children: [
            CircleAvatar(
              backgroundColor: Color(0xff21645c),
              foregroundColor: Colors.white,
              child: Icon(Icons.spa_outlined),
            ),
            SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'معاك',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 25),
                ),
                Text(
                  'مساحة أهدى ليومك',
                  style: TextStyle(fontSize: 12, color: Color(0xff6a756d)),
                ),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'عن التنبيهات',
            icon: const Icon(Icons.info_outline),
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => AlertDialog(
                title: const Text('علشان التذكير يوصلك'),
                content: const Text(
                  'فعّل الإشعارات وصلاحية المنبهات الدقيقة. التذكيرات المحلية لا تحتاج إنترنت، وتُستعاد بعد إعادة تشغيل الجهاز. '
                  'إيقاف التطبيق إجباريًا من إعدادات Android يمنع التنبيهات حتى تفتحه مجددًا. '
                  'اختبر تنبيهًا بعد دقيقة على جهازك قبل الاعتماد عليه.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('تمام'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openForm,
        backgroundColor: const Color(0xff21645c),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('تذكير جديد'),
      ),
      body: reminders.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('مش قادرين نقرأ التذكيرات دلوقتي.'),
              TextButton(
                onPressed: () => ref.invalidate(remindersProvider),
                child: const Text('إعادة المحاولة'),
              ),
            ],
          ),
        ),
        data: (all) {
          final active = all.where((r) => !r.isCompleted).toList()
            ..sort((a, b) => a.eventDateTime.compareTo(b.eventDateTime));
          final shown = _showCompleted
              ? all.where((r) => r.isCompleted).toList()
              : active;
          return ListView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 110),
            children: [
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: const Color(0xff21645c),
                  borderRadius: BorderRadius.circular(28),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      DateFormat(
                        'EEEE، d MMMM',
                        'ar_EG',
                      ).format(DateTime.now()),
                      style: const TextStyle(
                        color: Color(0xffc6e0d4),
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'كل موعد في باله.\nوإنت بالك مرتاح.',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 28,
                        height: 1.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        const Icon(
                          Icons.notifications_none_rounded,
                          color: Color(0xffdcebc5),
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${active.length} تذكير نشط',
                          style: const TextStyle(color: Colors.white),
                        ),
                        const Spacer(),
                        const Icon(
                          Icons.auto_awesome_outlined,
                          color: Color(0xffdcebc5),
                          size: 32,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Material(
                color: const Color(0xffe7ebdc),
                borderRadius: BorderRadius.circular(22),
                child: InkWell(
                  borderRadius: BorderRadius.circular(22),
                  onTap: widget.onOpenAssistant,
                  child: const Padding(
                    padding: EdgeInsets.all(20),
                    child: Row(
                      children: [
                        CircleAvatar(
                          backgroundColor: Color(0xfff9faf4),
                          child: Icon(Icons.mic_none_rounded),
                        ),
                        SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'قولها بطريقتك',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 17,
                                ),
                              ),
                              SizedBox(height: 4),
                              Text(
                                '«عندي دكتور بكرة الساعة خمسة مساءً»',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Color(0xff58665a),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Icon(Icons.arrow_back_rounded, size: 20),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 26),
              Row(
                children: [
                  const Text(
                    'تذكيراتك',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 22),
                  ),
                  const Spacer(),
                  FilterChip(
                    label: const Text('المكتملة'),
                    selected: _showCompleted,
                    onSelected: (value) =>
                        setState(() => _showCompleted = value),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (shown.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 30,
                    horizontal: 8,
                  ),
                  child: Column(
                    children: [
                      const Icon(
                        Icons.event_available_outlined,
                        size: 56,
                        color: Color(0xff829681),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _showCompleted
                            ? 'لسه مفيش تذكيرات مكتملة'
                            : 'يومك لسه صفحة جديدة',
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'أضف أول موعد، وهنفكّرك في الوقت اللي تختاره.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Color(0xff6a756d)),
                      ),
                    ],
                  ),
                ),
              ...shown.map(
                (r) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _ReminderCard(
                    reminder: r,
                    onEdit: () => _openForm(r),
                    onDelete: () => _delete(r),
                    onComplete: () => _act(
                      () =>
                          ref.read(reminderRepositoryProvider).complete(r.id!),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ReminderCard extends StatelessWidget {
  const _ReminderCard({
    required this.reminder,
    required this.onEdit,
    required this.onDelete,
    required this.onComplete,
  });
  final Reminder reminder;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onComplete;
  @override
  Widget build(BuildContext context) {
    final date = reminder.eventDateTime.toLocal();
    final past = date.isBefore(DateTime.now());
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 56,
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xfff1f1e9),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                children: [
                  Text(
                    DateFormat('d', 'ar_EG').format(date),
                    style: const TextStyle(
                      fontSize: 23,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    DateFormat('MMM', 'ar_EG').format(date),
                    style: const TextStyle(fontSize: 11),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    reminder.title,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      decoration: reminder.isCompleted
                          ? TextDecoration.lineThrough
                          : null,
                    ),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    DateFormat('EEEE · h:mm a', 'ar_EG').format(date),
                    style: const TextStyle(
                      color: Color(0xff627269),
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Icon(
                        Icons.notifications_outlined,
                        size: 13,
                        color: Color(0xff778569),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          reminder.isCompleted
                              ? 'مكتمل'
                              : past
                              ? 'انتهى الموعد'
                              : 'التنبيه ${DateFormat('d/M، h:mm a', 'ar_EG').format(reminder.reminderDateTime.toLocal())}',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xff778569),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              tooltip: 'خيارات التذكير',
              padding: EdgeInsets.zero,
              onSelected: (value) {
                switch (value) {
                  case 'edit':
                    onEdit();
                  case 'complete':
                    onComplete();
                  case 'delete':
                    onDelete();
                }
              },
              itemBuilder: (_) => [
                if (!reminder.isCompleted)
                  const PopupMenuItem(value: 'edit', child: Text('تعديل')),
                if (!reminder.isCompleted)
                  const PopupMenuItem(
                    value: 'complete',
                    child: Text('تم الموعد ✓'),
                  ),
                const PopupMenuItem(value: 'delete', child: Text('حذف')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

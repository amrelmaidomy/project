import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:timezone/timezone.dart' as tz;

import '../../core/app_exception.dart';
import '../wake_word/wake_word_service.dart';
import 'assistant_controller.dart';
import 'conversation_state.dart';

class AssistantScreen extends ConsumerStatefulWidget {
  const AssistantScreen({super.key});

  @override
  ConsumerState<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends ConsumerState<AssistantScreen>
    with WidgetsBindingObserver {
  final _text = TextEditingController();
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    if (lifecycle != AppLifecycleState.paused &&
        lifecycle != AppLifecycleState.detached) {
      return;
    }
    final controller = ref.read(assistantControllerProvider.notifier);
    final phase = ref.read(assistantControllerProvider).phase;
    if (phase == AssistantPhase.recording) {
      unawaited(controller.stopVoice());
    } else if (phase == AssistantPhase.preparing) {
      unawaited(controller.cancel());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _send() {
    final value = _text.text.trim();
    if (value.isEmpty) return;
    _text.clear();
    FocusScope.of(context).unfocus();
    unawaited(ref.read(assistantControllerProvider.notifier).submitText(value));
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(assistantControllerProvider);
    final controller = ref.read(assistantControllerProvider.notifier);
    final colors = Theme.of(context).colorScheme;
    ref.listen<ConversationState>(assistantControllerProvider, (
      previous,
      next,
    ) {
      if (previous?.messages.length != next.messages.length ||
          previous?.phase != next.phase) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _scroll.hasClients) {
            unawaited(
              _scroll.animateTo(
                _scroll.position.maxScrollExtent,
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOut,
              ),
            );
          }
        });
      }
    });
    return Scaffold(
      backgroundColor: const Color(0xfff8f8f2),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 24, 4),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(9),
                    decoration: BoxDecoration(
                      color: const Color(0xffe5eee4),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(
                      Icons.auto_awesome_rounded,
                      size: 21,
                      color: Color(0xff21645c),
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'المساعد',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 20,
                      ),
                    ),
                  ),
                  if (state.messages.isNotEmpty || state.isBusy)
                    IconButton(
                      tooltip: 'إلغاء المحادثة وبدء تذكير جديد',
                      onPressed: state.phase == AssistantPhase.saving
                          ? null
                          : controller.startOver,
                      icon: const Icon(Icons.refresh_rounded),
                    ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (state.messages.isEmpty) ...[
                      const _WakeWordCard(),
                      const SizedBox(height: 24),
                      const Text(
                        'قول لي،\nأفكّرك بإيه؟',
                        style: TextStyle(
                          fontSize: 33,
                          height: 1.4,
                          fontWeight: FontWeight.w800,
                          color: Color(0xff153d36),
                        ),
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        'احكي لي عن موعدك، وأنا أرتّب التذكير معاك.',
                        style: TextStyle(
                          color: Color(0xff69766e),
                          fontSize: 16,
                          height: 1.7,
                        ),
                      ),
                      const SizedBox(height: 30),
                      Center(
                        child: _MicrophoneButton(
                          large: true,
                          recording: state.microphoneActive,
                          busy:
                              state.isBusy &&
                              state.phase != AssistantPhase.recording,
                          onPressed: state.phase == AssistantPhase.recording
                              ? controller.stopVoice
                              : controller.startVoice,
                        ),
                      ),
                      const SizedBox(height: 20),
                      _Status(state: state),
                      const SizedBox(height: 32),
                      Container(
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: const Color(0xffe8eae1)),
                        ),
                        child: const Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'قول مثلاً',
                              style: TextStyle(
                                color: Color(0xff69766e),
                                fontSize: 13,
                              ),
                            ),
                            SizedBox(height: 8),
                            Text(
                              '«عندي دكتور بكرة الساعة خمسة مساءً، '
                              'فكّرني قبله بساعتين»',
                              style: TextStyle(fontSize: 16, height: 1.8),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 18),
                      const Text(
                        'قول صباحًا أو مساءً علشان نتأكد من الساعة. '
                        'ولو في تفاصيل ناقصة، هسألك عنها.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Color(0xff69766e),
                          fontSize: 13,
                          height: 1.8,
                        ),
                      ),
                    ],
                    for (final message in state.messages)
                      _MessageBubble(message: message),
                    if (state.messages.isNotEmpty &&
                        (state.isBusy ||
                            state.phase == AssistantPhase.awaitingDetails)) ...[
                      const SizedBox(height: 12),
                      _Status(state: state),
                    ],
                    if (state.latestTranscript != null) ...[
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(15),
                        decoration: BoxDecoration(
                          color: const Color(0xffedf0e8),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Row(
                              children: [
                                Icon(
                                  Icons.graphic_eq_rounded,
                                  size: 17,
                                  color: Color(0xff657a6b),
                                ),
                                SizedBox(width: 6),
                                Text(
                                  'سمعت منك',
                                  style: TextStyle(
                                    color: Color(0xff657a6b),
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 7),
                            SelectableText(
                              state.latestTranscript!,
                              style: const TextStyle(height: 1.7),
                            ),
                          ],
                        ),
                      ),
                    ],
                    if (state.phase == AssistantPhase.awaitingConfirmation ||
                        state.phase == AssistantPhase.saving) ...[
                      const SizedBox(height: 20),
                      _ConfirmationCard(
                        draft: state.draft,
                        saving: state.phase == AssistantPhase.saving,
                        onConfirm: controller.confirm,
                        onEdit: controller.edit,
                        onCancel: controller.cancel,
                      ),
                    ],
                    if (state.error != null) ...[
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: colors.errorContainer,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              state.error!,
                              style: TextStyle(
                                color: colors.onErrorContainer,
                                height: 1.7,
                              ),
                            ),
                            if (state.phase == AssistantPhase.error &&
                                !state.saveUncertain &&
                                state.lastSubmittedText != null)
                              TextButton.icon(
                                onPressed: controller.retryLastText,
                                icon: const Icon(Icons.refresh_rounded),
                                label: const Text('إعادة المحاولة'),
                              ),
                            if (state.saveUncertain)
                              TextButton(
                                onPressed: controller.startOver,
                                child: const Text('بدء محادثة جديدة'),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _text,
                      enabled: !state.isBusy && !state.saveUncertain,
                      minLines: 1,
                      maxLines: 4,
                      maxLength: 2000,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: InputDecoration(
                        counterText: '',
                        hintText: state.phase == AssistantPhase.awaitingDetails
                            ? 'اكتب التفاصيل الناقصة…'
                            : 'أو اكتب التذكير هنا…',
                        filled: true,
                        fillColor: Colors.white,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 17,
                          vertical: 16,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(22),
                          borderSide: const BorderSide(
                            color: Color(0xffe1e6dc),
                          ),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(22),
                          borderSide: const BorderSide(
                            color: Color(0xffe1e6dc),
                          ),
                        ),
                        suffixIcon: IconButton(
                          tooltip: 'إرسال النص',
                          onPressed: state.isBusy || state.saveUncertain
                              ? null
                              : _send,
                          icon: const Icon(Icons.arrow_upward_rounded),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  _MicrophoneButton(
                    recording: state.microphoneActive,
                    enabled: !state.saveUncertain,
                    busy:
                        (state.isBusy &&
                        state.phase != AssistantPhase.recording),
                    onPressed: state.phase == AssistantPhase.recording
                        ? controller.stopVoice
                        : controller.startVoice,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WakeWordCard extends ConsumerStatefulWidget {
  const _WakeWordCard();

  @override
  ConsumerState<_WakeWordCard> createState() => _WakeWordCardState();
}

class _WakeWordCardState extends ConsumerState<_WakeWordCard> {
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_refresh());
    });
  }

  Future<void> _refresh() async {
    try {
      await ref.read(wakeWordServiceProvider).refresh();
    } catch (_) {
      // Button recording and text entry remain available on unsupported devices.
    }
  }

  Future<void> _toggle(bool enable, {String profile = 'ya_mosaed'}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final service = ref.read(wakeWordServiceProvider);
      if (enable) {
        await service.start(profile: profile);
      } else {
        await service.stop();
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error is AppException
              ? error.message
              : 'تعذّر تفعيل الاستماع التلقائي. '
                    'اتأكد من صلاحيات الميكروفون والإشعارات وجرّب تاني.';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(wakeWordServiceProvider);
    final conversationBusy = ref.watch(
      assistantControllerProvider.select((state) => state.isBusy),
    );
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final status = service.status;
        final demo = status.enabled && status.profile == 'hey_jarvis';
        final title = demo ? 'استماع تجريبي: Hey Jarvis' : 'ناديني «يا مساعد»';
        final description = status.enabled
            ? status.listening
                  ? 'الاستماع شغّال مع إشعار دائم. تقدر توقفه في أي وقت.'
                  : 'الاستماع متوقف مؤقتًا أثناء المحادثة.'
            : status.available
            ? 'فعّل الاستماع بالميكروفون مع إشعار دائم علشان تناديني بصوتك.'
            : 'عبارة «يا مساعد» محتاجة نموذج صوتي مخصص قبل التفعيل. '
                  'تقدر تستخدم زر الميكروفون دلوقتي.';
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xffedf0e7),
            borderRadius: BorderRadius.circular(19),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.hearing_rounded,
                    color: Color(0xff21645c),
                    size: 23,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  if (_busy)
                    const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    Switch.adaptive(
                      value: status.enabled,
                      onChanged:
                          !conversationBusy &&
                              (status.available || status.enabled)
                          ? (value) => _toggle(value)
                          : null,
                    ),
                ],
              ),
              Text(
                description,
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.8,
                  color: Color(0xff607165),
                ),
              ),
              if (!status.enabled && status.demoAvailable)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton(
                    onPressed: _busy || conversationBusy
                        ? null
                        : () => _toggle(true, profile: 'hey_jarvis'),
                    child: const Text('تجربة عبارة Hey Jarvis'),
                  ),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontSize: 12,
                      height: 1.7,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _MicrophoneButton extends StatelessWidget {
  const _MicrophoneButton({
    required this.recording,
    required this.busy,
    required this.onPressed,
    this.large = false,
    this.enabled = true,
  });

  final bool recording;
  final bool busy;
  final bool large;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final color = recording ? const Color(0xffad463e) : const Color(0xff21645c);
    return Semantics(
      button: true,
      label: recording ? 'إيقاف التسجيل' : 'بدء التسجيل الصوتي',
      child: Tooltip(
        message: recording ? 'إيقاف التسجيل' : 'اتكلم مع المساعد',
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: large ? 106 : 56,
          height: large ? 106 : 56,
          decoration: BoxDecoration(
            color: color.withValues(alpha: busy || !enabled ? .5 : 1),
            shape: BoxShape.circle,
            boxShadow: large
                ? [
                    BoxShadow(
                      color: color.withValues(alpha: .15),
                      blurRadius: 0,
                      spreadRadius: 11,
                    ),
                    BoxShadow(
                      color: color.withValues(alpha: .07),
                      blurRadius: 0,
                      spreadRadius: 22,
                    ),
                  ]
                : null,
          ),
          child: IconButton(
            onPressed: busy || !enabled ? null : onPressed,
            color: Colors.white,
            iconSize: large ? 42 : 25,
            icon: busy
                ? SizedBox(
                    width: large ? 30 : 23,
                    height: large ? 30 : 23,
                    child: const CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Icon(recording ? Icons.stop_rounded : Icons.mic_rounded),
          ),
        ),
      ),
    );
  }
}

class _Status extends StatelessWidget {
  const _Status({required this.state});
  final ConversationState state;

  @override
  Widget build(BuildContext context) {
    final label = switch (state.phase) {
      AssistantPhase.preparing => 'معاك… لحظة وهبدأ أسمعك',
      AssistantPhase.recording => 'بسمعك… اضغط إيقاف لما تخلص',
      AssistantPhase.transcribing => 'بحوّل كلامك لنص…',
      AssistantPhase.parsing => 'برتب تفاصيل الموعد…',
      AssistantPhase.saving => 'بحفظ التذكير وبضبط التنبيه…',
      AssistantPhase.awaitingDetails =>
        'مستني التفاصيل منك، بالصوت أو بالكتابة',
      _ => 'اضغط على الميكروفون واتكلم براحتك',
    };
    return Semantics(
      liveRegion: true,
      child: Column(
        children: [
          Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Color(0xff52675b),
              fontSize: 14,
              height: 1.6,
            ),
          ),
          if (state.microphoneActive && state.recordingStartedAt != null)
            _RecordingTime(startedAt: state.recordingStartedAt!),
        ],
      ),
    );
  }
}

class _RecordingTime extends StatefulWidget {
  const _RecordingTime({required this.startedAt});
  final DateTime startedAt;

  @override
  State<_RecordingTime> createState() => _RecordingTimeState();
}

class _RecordingTimeState extends State<_RecordingTime> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final seconds = DateTime.now().difference(widget.startedAt).inSeconds;
    final value = seconds.clamp(0, 60);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        '00:${value.toString().padLeft(2, '0')} / 01:00',
        textDirection: TextDirection.ltr,
        style: const TextStyle(color: Color(0xffad463e), fontSize: 13),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});
  final ConversationMessage message;

  @override
  Widget build(BuildContext context) => Align(
    alignment: message.isUser
        ? AlignmentDirectional.centerEnd
        : AlignmentDirectional.centerStart,
    child: Container(
      constraints: const BoxConstraints(maxWidth: 420),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 13),
      decoration: BoxDecoration(
        color: message.isUser ? const Color(0xff21645c) : Colors.white,
        borderRadius: BorderRadius.circular(19),
        border: message.isUser
            ? null
            : Border.all(color: const Color(0xffe8eae1)),
      ),
      child: Text(
        message.text,
        style: TextStyle(
          color: message.isUser ? Colors.white : const Color(0xff263e32),
          height: 1.8,
          fontSize: 15,
        ),
      ),
    ),
  );
}

class _ConfirmationCard extends StatelessWidget {
  const _ConfirmationCard({
    required this.draft,
    required this.saving,
    required this.onConfirm,
    required this.onEdit,
    required this.onCancel,
  });
  final ReminderDraft draft;
  final bool saving;
  final VoidCallback onConfirm;
  final VoidCallback onEdit;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    // Normal operation follows the device timezone, like the manual form.
    // If platform timezone lookup failed, show the explicitly chosen fallback.
    final event = draft.timezoneFallback
        ? tz.TZDateTime.from(
            draft.eventDateTime!,
            tz.getLocation(draft.timezone),
          )
        : draft.eventDateTime!.toLocal();
    final reminder = draft.timezoneFallback
        ? tz.TZDateTime.from(
            draft.reminderDateTime!,
            tz.getLocation(draft.timezone),
          )
        : draft.reminderDateTime!.toLocal();
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(23),
        border: Border.all(color: const Color(0xffcbd9c7)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Row(
            children: [
              Icon(Icons.fact_check_outlined, color: Color(0xff21645c)),
              SizedBox(width: 9),
              Expanded(
                child: Text(
                  'راجع الموعد قبل الحفظ',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: Color(0xff21645c),
                    fontSize: 16,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Text(
            draft.title!,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 16),
          _DetailRow(
            icon: Icons.calendar_today_outlined,
            title: DateFormat('EEEE، d MMMM y', 'ar_EG').format(event),
          ),
          const SizedBox(height: 12),
          _DetailRow(
            icon: Icons.schedule_rounded,
            title:
                '${DateFormat('h:mm a', 'ar_EG').format(event)} · ${draft.timezone}',
          ),
          if (draft.timezoneFallback)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text(
                'تعذّر تحديد منطقة الجهاز. الموعد هنا بتوقيت القاهرة؛ '
                'اتأكد إن التوقيت مناسب قبل الحفظ.',
                style: TextStyle(color: Color(0xff8b5d29), height: 1.7),
              ),
            ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              color: const Color(0xffedf3e7),
              borderRadius: BorderRadius.circular(14),
            ),
            child: _DetailRow(
              icon: Icons.notifications_active_outlined,
              title:
                  'التنبيه ${DateFormat('EEEE d MMMM، h:mm a', 'ar_EG').format(reminder)}',
            ),
          ),
          const SizedBox(height: 22),
          FilledButton.icon(
            onPressed: saving ? null : onConfirm,
            icon: saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check_rounded),
            label: Text(saving ? 'بنحفظ التذكير…' : 'تأكيد وحفظ'),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: TextButton.icon(
                  onPressed: saving ? null : onEdit,
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text('تعديل التفاصيل'),
                ),
              ),
              TextButton(
                onPressed: saving ? null : onCancel,
                child: const Text('إلغاء'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.icon, required this.title});
  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 20, color: const Color(0xff657a6b)),
      const SizedBox(width: 10),
      Expanded(child: Text(title, style: const TextStyle(height: 1.6))),
    ],
  );
}

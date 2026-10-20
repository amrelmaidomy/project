import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/providers.dart';
import 'features/assistant/assistant_controller.dart';
import 'features/assistant/assistant_screen.dart';
import 'features/assistant/conversation_state.dart';
import 'features/reminders/screens/reminders_screen.dart';
import 'features/wake_word/wake_word_service.dart';
import 'features/wake_word/background_reminders.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: ReminderApp()));
}

@pragma('vm:entry-point')
void rafiqBackgroundMain() => startRafiqBackground();

class ReminderApp extends StatelessWidget {
  const ReminderApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'معاك · مساعد المواعيد',
    debugShowCheckedModeBanner: false,
    locale: const Locale('ar', 'EG'),
    supportedLocales: const [Locale('ar', 'EG')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff21645c),
        primary: const Color(0xff21645c),
        surface: const Color(0xfffbfaf7),
      ),
      scaffoldBackgroundColor: const Color(0xfff5f4ee),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xfff5f4ee),
        scrolledUnderElevation: 0,
        centerTitle: false,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: Color(0xffdedfd6)),
        ),
        contentPadding: const EdgeInsets.all(18),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
    ),
    home: const HomeShell(),
  );
}

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell>
    with WidgetsBindingObserver {
  int _tab = 0;
  String? _startupError;
  StreamSubscription<WakeWordDetection>? _wakeSubscription;
  late final WakeWordService _wake;
  int _reminderRevision = 0;

  void _onWakeStatus() {
    final revision = ref.read(wakeWordServiceProvider).status.reminderRevision;
    if (revision == _reminderRevision) return;
    _reminderRevision = revision;
    ref.invalidate(remindersProvider);
  }

  void _selectTab(int value) {
    if (_tab == 1 && value != 1) {
      final phase = ref.read(assistantControllerProvider).phase;
      if (phase == AssistantPhase.recording ||
          phase == AssistantPhase.preparing) {
        ref.read(assistantControllerProvider.notifier).cancel();
      }
    }
    setState(() => _tab = value);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _restoreSchedules();
    final wake = ref.read(wakeWordServiceProvider);
    _wake = wake;
    wake.addListener(_onWakeStatus);
    _wakeSubscription = wake.detections.listen((_) {
      if (!mounted ||
          !wake.status.enabled ||
          ref.read(assistantControllerProvider).isBusy) {
        return;
      }
      if (ModalRoute.of(context)?.isCurrent != true) {
        unawaited(wake.resumeAfterRecording());
        return;
      }
      _selectTab(1);
      unawaited(ref.read(assistantControllerProvider.notifier).startVoice());
    });
    unawaited(wake.refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _wake.removeListener(_onWakeStatus);
    unawaited(_wakeSubscription?.cancel());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.invalidate(remindersProvider);
      _restoreSchedules();
    }
  }

  Future<void> _restoreSchedules() async {
    try {
      await ref.read(notificationServiceProvider).initialize();
      await ref.read(reminderRepositoryProvider).rescheduleFuture();
      if (mounted) setState(() => _startupError = null);
    } catch (_) {
      if (mounted) {
        setState(
          () => _startupError =
              'فعّل الإشعارات والمنبهات الدقيقة من إعدادات التطبيق، ثم أعد المحاولة.',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Column(
        children: [
          if (_startupError != null)
            MaterialBanner(
              content: Text(_startupError!),
              leading: const Icon(Icons.notifications_paused_outlined),
              actions: [
                TextButton(
                  onPressed: _restoreSchedules,
                  child: const Text('إعادة المحاولة'),
                ),
              ],
            ),
          Expanded(
            child: IndexedStack(
              index: _tab,
              children: [
                RemindersScreen(onOpenAssistant: () => _selectTab(1)),
                const AssistantScreen(),
              ],
            ),
          ),
        ],
      ),
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: _tab,
      onDestinationSelected: _selectTab,
      backgroundColor: const Color(0xfffbfaf7),
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.calendar_today_outlined),
          selectedIcon: Icon(Icons.calendar_month),
          label: 'مواعيدي',
        ),
        NavigationDestination(
          icon: Icon(Icons.mic_none_rounded),
          selectedIcon: Icon(Icons.mic_rounded),
          label: 'المساعد',
        ),
      ],
    ),
  );
}

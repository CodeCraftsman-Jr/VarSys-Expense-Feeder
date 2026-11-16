import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/icons.dart';

import '../../ingestion/email/email_sync.dart';
import '../../ingestion/ingestion_service.dart';
import '../../llm/llm_providers.dart';
import '../../providers.dart';
import '../settings/background_sync_setup.dart';
import 'share_outcome.dart';

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key, required this.shell});

  final StatefulNavigationShell shell;

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // Pull new SMS (and email) whenever the app comes to the foreground.
    _lifecycle = AppLifecycleListener(onResume: _sync);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _sync();
      await ref.read(smsAlertsProvider.notifier).ensurePermission();
      // Background sync needs the battery exemption (and Autostart on Xiaomi): ask for it here.
      if (mounted && ref.read(smsSyncProvider).enabled) {
        await askBackgroundSync(context, ref.read(prefsProvider));
      }
    });
  }

  Future<void> _sync() => Future.wait([
    ref.read(smsSyncProvider.notifier).sync().then(_announce),
    ref.read(emailSyncProvider.notifier).syncIfDue().then(_announce),
  ]);

  void _announce(IngestReport? report) {
    if (!mounted || report == null || report.added + report.merged == 0) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${report.added} new transaction${report.added == 1 ? '' : 's'}'
          '${report.merged > 0 ? ' · ${report.merged} duplicate${report.merged == 1 ? '' : 's'} merged' : ''}',
        ),
      ),
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final index = widget.shell.currentIndex;
    // Keeps the AI jobs alive so they run after each sync.
    ref.listen(aiJobsProvider, (_, _) {});
    ref.listen(shareIntakeProvider, (_, outcome) {
      if (outcome != null) showShareOutcome(context, outcome);
    });
    return Scaffold(
      body: widget.shell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (i) => widget.shell.goBranch(i, initialLocation: i == index),
        destinations: [
          const NavigationDestination(
            icon: Icon(PhosphorIconsRegular.listBullets),
            selectedIcon: Icon(PhosphorIconsFill.listBullets),
            label: 'Activity',
          ),
          const NavigationDestination(
            icon: Icon(PhosphorIconsRegular.gearSix),
            selectedIcon: Icon(PhosphorIconsFill.gearSix),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}

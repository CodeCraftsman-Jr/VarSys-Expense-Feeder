import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moneytrail/core/theme/app_theme.dart';
import 'package:moneytrail/features/settings/background_sync_tile.dart';

/// The tile sits inside the SMS card in Settings. It once put a button in a ListTile's trailing slot,
/// which gets unbounded width: the whole card failed to lay out and painted blank on a real phone.
void main() {
  const channel = MethodChannel('moneytrail/device');

  Future<void> pumpTile(WidgetTester tester, {required bool unrestricted, required bool autostart}) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'batteryUnrestricted':
          return unrestricted;
        case 'autostartPage':
          return autostart;
      }
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    // A narrow phone, like the card it lives in.
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        // The app theme matters: it gives buttons a full-width minimum size.
        theme: AppTheme.dark(),
        home: const Scaffold(
          body: SingleChildScrollView(
            child: Card(child: Column(children: [BackgroundSyncTile()])),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('asks for battery access with an Allow button and lays out without errors', (tester) async {
    await pumpTile(tester, unrestricted: false, autostart: false);
    expect(tester.takeException(), isNull);
    expect(find.text('Background sync'), findsOneWidget);
    expect(find.text('Allow'), findsOneWidget);
  });

  testWidgets('shows Autostart on phones that have the page, and lays out without errors', (tester) async {
    await pumpTile(tester, unrestricted: false, autostart: true);
    expect(tester.takeException(), isNull);
    expect(find.text('Autostart'), findsOneWidget);
    expect(find.text('Open'), findsOneWidget);
  });

  testWidgets('shows the allowed state without a button', (tester) async {
    await pumpTile(tester, unrestricted: true, autostart: false);
    expect(tester.takeException(), isNull);
    expect(find.text('Background sync'), findsOneWidget);
    expect(find.text('Allow'), findsNothing);
  });
}

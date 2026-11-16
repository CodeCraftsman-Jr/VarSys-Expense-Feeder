
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'background/background_sync.dart';
import 'ingestion/share/share_intake.dart';
import 'core/secrets.dart';
import 'providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Before runApp: its route observer must precede the router's (iOS links).
  IncomingShares.instance.start();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  final prefs = await SharedPreferences.getInstance();
  await _forgetAiSettings(prefs);
  runApp(ProviderScope(overrides: [prefsProvider.overrideWithValue(prefs)], child: const MoneyTrailApp()));
}

/// The phone no longer has any AI features. Once, wipe the provider keys and settings an earlier
/// version saved, so nothing sensitive stays behind where no screen can reach it.
Future<void> _forgetAiSettings(SharedPreferences prefs) async {
  const done = 'ai.settings.forgotten';
  if (prefs.getBool(done) ?? false) return;
  try {
    const providers = ['openai', 'anthropic', 'gemini', 'openrouter', 'groq', 'deepseek', 'ollama', 'lmstudio', 'custom', 'ondevice'];
    final secrets = SecretStore();
    for (final id in providers) {
      await secrets.delete('llm.apiKey.$id');
    }
    for (final key in prefs.getKeys().where((k) => k.startsWith('llm.')).toList()) {
      await prefs.remove(key);
    }
    await prefs.setBool(done, true);
  } catch (e) {
    debugPrint('Could not clear old AI settings: $e');
  }
}

/// Entry point for SyncWorker.kt (Android): imports new SMS and syncs Joint
/// Journey while the app is closed. Looked up by name in this library.
@pragma('vm:entry-point')
Future<void> backgroundSync() => runBackgroundSync();

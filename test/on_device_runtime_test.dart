import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moneytrail/data/db/database.dart';
import 'package:moneytrail/llm/llm_client.dart';
import 'package:moneytrail/llm/llm_config.dart';
import 'package:moneytrail/llm/llm_providers.dart';
import 'package:moneytrail/llm/on_device/model_catalog.dart';
import 'package:moneytrail/llm/on_device/on_device_client.dart';
import 'package:moneytrail/llm/on_device/on_device_models.dart';
import 'package:moneytrail/llm/on_device/on_device_scheduler.dart';
import 'package:moneytrail/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'db_encryption_test.dart' show MemorySecretStore;

/// A small-context client like the on-device one: records requests.
class FakeSmallLlm implements LlmClient, LlmBudget, LlmStreamingClient {
  FakeSmallLlm(this.script, {this.contextTokens = 4096});
  final List<LlmResponse Function(List<LlmMessage>)> script;
  final requests = <({List<LlmMessage> messages, int maxTokens})>[];

  @override
  final int contextTokens;

  @override
  bool get supportsTools => true;

  @override
  String get providerId => 'fake-small';

  @override
  Future<LlmResponse> chat({
    String? system,
    required List<LlmMessage> messages,
    List<LlmTool> tools = const [],
    int maxTokens = 4096,
  }) async {
    requests.add((messages: List.of(messages), maxTokens: maxTokens));
    return script.isEmpty
        ? const LlmResponse(
            message: AssistantMessage(text: '{}'),
            stop: LlmStop.endTurn,
          )
        : script.removeAt(0)(messages);
  }

  @override
  Future<LlmResponse> chatStreaming({
    String? system,
    required List<LlmMessage> messages,
    List<LlmTool> tools = const [],
    int maxTokens = 4096,
    required void Function(String textSoFar) onText,
  }) async {
    final r = await chat(system: system, messages: messages, tools: tools, maxTokens: maxTokens);
    if (r.toolCalls.isEmpty) {
      for (var i = 1; i <= r.text.length; i += 4) {
        onText(r.text.substring(0, i));
      }
      onText(r.text);
    }
    return r;
  }

  @override
  Future<List<String>> listModels() async => const [];
}

LlmResponse _call(String name, Map<String, dynamic> args) => LlmResponse(
  message: AssistantMessage(
    toolCalls: [ToolCall(id: 'c', name: name, arguments: args)],
  ),
  stop: LlmStop.toolUse,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('scheduler', () {
    test('interactive requests jump ahead of queued background work', () async {
      final s = OnDeviceScheduler(idleAfter: const Duration(hours: 1));
      final order = <String>[];
      final gate = Completer<void>();
      final first = s.run(OnDevicePriority.background, (_) async {
        await gate.future;
        order.add('bg1');
      });
      await Future<void>.delayed(Duration.zero); // bg1 is now running
      final bg2 = s.run(OnDevicePriority.background, (_) async => order.add('bg2'));
      final ask = s.run(OnDevicePriority.interactive, (_) async => order.add('ask'));
      expect(s.interactivePending, isTrue);
      gate.complete();
      // bg1 was running and had no stop hook, so it was flagged and finishes.
      await first;
      await ask;
      await expectLater(bg2, completes);
      expect(order, ['bg1', 'ask', 'bg2']);
      expect(s.interactivePending, isFalse);
    });

    test('an Ask request stops the running background generation', () async {
      final s = OnDeviceScheduler(idleAfter: const Duration(hours: 1));
      final stopped = Completer<void>();
      final bg = s.run(OnDevicePriority.background, (run) async {
        final generation = Completer<String>();
        run.onPreempt(() {
          stopped.complete();
          generation.complete('stopped');
        });
        final r = await generation.future;
        if (run.preempted) throw const OnDevicePreempted();
        return r;
      });
      await Future<void>.delayed(Duration.zero);
      final ask = s.run(OnDevicePriority.interactive, (_) async => 'answer');
      await stopped.future;
      await expectLater(bg, throwsA(isA<OnDevicePreempted>()));
      expect(await ask, 'answer');
    });

    test('background never preempts interactive', () async {
      final s = OnDeviceScheduler(idleAfter: const Duration(hours: 1));
      var stopCalled = false;
      final gate = Completer<void>();
      final ask = s.run(OnDevicePriority.interactive, (run) async {
        run.onPreempt(() => stopCalled = true);
        await gate.future;
        return 'ok';
      });
      final bg = s.run(OnDevicePriority.background, (_) async => 'bg');
      gate.complete();
      expect(await ask, 'ok');
      expect(await bg, 'bg');
      expect(stopCalled, isFalse);
    });

    test('fires onIdle after the idle period and whenQuiet waits for it', () async {
      var idle = 0;
      final s = OnDeviceScheduler(idleAfter: const Duration(milliseconds: 50), onIdle: () => idle++);
      await s.run(OnDevicePriority.interactive, (_) async {});
      final sw = Stopwatch()..start();
      await s.whenQuiet(const Duration(milliseconds: 30));
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(20));
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(idle, 1);
    });

    test('turn timeouts scale with model size and job kind', () {
      final e2b = onDeviceTurnTimeout(
        modelBytes: ModelCatalog.gemma4E2b.sizeBytes,
        priority: OnDevicePriority.interactive,
      );
      final e4b = onDeviceTurnTimeout(
        modelBytes: ModelCatalog.gemma4E4b.sizeBytes,
        priority: OnDevicePriority.interactive,
      );
      final e2bBatch = onDeviceTurnTimeout(
        modelBytes: ModelCatalog.gemma4E2b.sizeBytes,
        priority: OnDevicePriority.background,
      );
      expect(e2b.inSeconds, inInclusiveRange(150, 240));
      expect(e4b > e2b, isTrue);
      expect(e2bBatch, e2b * 2);
    });
  });

  group('conversation reuse', () {
    const q1 = UserMessage('How much on food?');
    final call = _call('spending_summary', {'group_by': 'category'}).message;
    const results = ToolResultsMessage([ToolResult(callId: 'c', name: 'spending_summary', content: '{}')]);

    test('a transcript that extends the live one only sends the new messages', () {
      expect(continuationOf([q1, call], [q1, call, results], sameSignature: true), [results]);
    });

    test('anything else starts over', () {
      expect(continuationOf([q1, call], [q1, call, results], sameSignature: false), isNull);
      expect(continuationOf([q1, call], [UserMessage(q1.text), call, results], sameSignature: true), isNull);
      expect(continuationOf([q1, call], [q1, call], sameSignature: true), isNull);
      expect(continuationOf([q1], [q1, const AssistantMessage(text: 'x')], sameSignature: true), isNull);
    });

    test('replaying an old chat keeps earlier questions and answers only', () {
      const a1 = AssistantMessage(text: 'You spent ₹4,200.');
      const q2 = UserMessage('And travel?');
      final compact = compactForReplay([q1, call, results, a1, q2, call, results]);
      expect(compact, [q1, a1, q2, call, results]);
    });

    test('signature changes with the system prompt, tools and output cap', () {
      const tool = LlmTool(name: 'a', description: 'd', parameters: {});
      final base = conversationSignature('m', 'sys', [tool], 1024);
      expect(conversationSignature('m', 'sys', [tool], 1024), base);
      expect(conversationSignature('m', 'sys2', [tool], 1024), isNot(base));
      expect(conversationSignature('m', 'sys', const [], 1024), isNot(base));
      expect(conversationSignature('m', 'sys', [tool], 512), isNot(base));
    });
  });

  group('background jobs', () {
    late AppDatabase db;
    setUp(() async {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      db = AppDatabase(DatabaseConnection(NativeDatabase.memory()));
      final other = (await db.allCategories()).firstWhere((c) => c.name == 'Other');
      for (var i = 0; i < 40; i++) {
        await db
            .into(db.transactions)
            .insert(
              TransactionsCompanion.insert(
                amountMinor: 1000 + i,
                direction: TxnDirection.debit,
                occurredAt: DateTime(2026, 10, 1).add(Duration(hours: i)),
                mode: PaymentMode.upi,
                status: TxnStatus.confirmed,
                merchant: Value('m$i'),
                categoryId: Value(other.id),
              ),
            );
      }
    });
    tearDown(() => db.close());

    test('policy: every 6 h, every 30 min while charging', () {
      const p = OnDeviceJobPolicy();
      final now = DateTime(2026, 10, 20, 12);
      expect(p.shouldAutoRun(lastRun: null, now: now, charging: false), isTrue);
      expect(p.shouldAutoRun(lastRun: now.subtract(const Duration(hours: 1)), now: now, charging: false), isFalse);
      expect(p.shouldAutoRun(lastRun: now.subtract(const Duration(hours: 1)), now: now, charging: true), isTrue);
      expect(p.shouldAutoRun(lastRun: now.subtract(const Duration(hours: 7)), now: now, charging: false), isTrue);
    });

    Future<(ProviderContainer, FakeSmallLlm)> container({int? lastRunAgoMinutes, bool interactive = false}) async {
      SharedPreferences.setMockInitialValues({
        if (lastRunAgoMinutes != null)
          AiJobsController.lastAutoRunKey: DateTime.now()
              .subtract(Duration(minutes: lastRunAgoMinutes))
              .millisecondsSinceEpoch,
      });
      final prefs = await SharedPreferences.getInstance();
      await const LlmConfig(presetId: 'ondevice', model: 'gemma-4-e2b', aiReadUnparsed: true).save(prefs);
      final llm = FakeSmallLlm([]);
      final runtime = OnDeviceRuntime();
      final c = ProviderContainer(
        overrides: [
          prefsProvider.overrideWithValue(prefs),
          databaseProvider.overrideWithValue(db),
          llmClientProvider.overrideWith((ref) async => llm),
          aiJobsProvider.overrideWith(
            () => AiJobsController(
              policy: const OnDeviceJobPolicy(startDelay: Duration.zero, quietBeforeStart: Duration.zero),
              isCharging: () async => false,
              isForeground: () => !interactive,
              runtime: runtime,
            ),
          ),
        ],
      );
      addTearDown(c.dispose);
      return (c, llm);
    }

    test('on-device auto-run waits for the interval', () async {
      final (c, llm) = await container(lastRunAgoMinutes: 60);
      await c.read(aiJobsProvider.notifier).runAfterSync();
      expect(llm.requests, isEmpty);
    });

    test('on-device auto-run does not start while the user needs the phone', () async {
      final (c, llm) = await container(interactive: true);
      await c.read(aiJobsProvider.notifier).runAfterSync();
      expect(llm.requests, isEmpty);
      expect(c.read(prefsProvider).getInt(AiJobsController.lastAutoRunKey), isNull);
    });
  });

  test('picking the on-device provider leaves background AI off', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await const LlmConfig(
      presetId: 'openai',
      model: 'gpt-5-mini',
      aiReadUnparsed: true,
    ).save(prefs);
    final c = ProviderContainer(
      overrides: [prefsProvider.overrideWithValue(prefs), secretStoreProvider.overrideWithValue(MemorySecretStore())],
    );
    addTearDown(c.dispose);
    await c.read(onDeviceModelsProvider.notifier).use(ModelCatalog.gemma4E2b);
    final cfg = c.read(llmConfigProvider);
    expect(cfg.presetId, 'ondevice');
    expect(cfg.aiReadUnparsed, isFalse);

    // Choices made while on-device are kept when re-picking a model.
    await c.read(llmConfigProvider.notifier).change((x) => x.copyWith(aiReadUnparsed: true));
    await c.read(onDeviceModelsProvider.notifier).use(ModelCatalog.gemma4E4b);
    expect(c.read(llmConfigProvider).aiReadUnparsed, isTrue);
  });
}

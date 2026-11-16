import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moneytrail/data/db/database.dart';
import 'package:moneytrail/ingestion/ingestion_service.dart';
import 'package:moneytrail/ingestion/parser/parsed_txn.dart';
import 'package:moneytrail/llm/fallback_parser.dart';
import 'package:moneytrail/llm/llm_client.dart';

/// Replays scripted responses and records every request.
class FakeLlm implements LlmClient {
  FakeLlm(this.script);
  final List<LlmResponse Function(List<LlmMessage> messages)> script;
  final calls = <({String? system, List<LlmMessage> messages, List<LlmTool> tools})>[];

  @override
  String get providerId => 'fake';

  @override
  Future<LlmResponse> chat({
    String? system,
    required List<LlmMessage> messages,
    List<LlmTool> tools = const [],
    int maxTokens = 4096,
  }) async {
    calls.add((system: system, messages: List.of(messages), tools: tools));
    return script.removeAt(0)(messages);
  }

  @override
  Future<List<String>> listModels() async => const ['fake'];
}

LlmResponse text(String t) => LlmResponse(
  message: AssistantMessage(text: t),
  stop: LlmStop.endTurn,
);

LlmResponse toolCall(String name, Map<String, dynamic> args, {String id = 'c1'}) => LlmResponse(
  message: AssistantMessage(
    toolCalls: [ToolCall(id: id, name: name, arguments: args)],
  ),
  stop: LlmStop.toolUse,
);

void main() {
  late AppDatabase db;
  late IngestionService svc;
  var seq = 0;
  final t0 = DateTime(2026, 10, 12, 20, 0);

  RawInput sms(String sender, String body, DateTime at) =>
      RawInput(source: SourceKind.sms, externalId: 's${seq++}', sender: sender, body: body, receivedAt: at);

  Future<RawMessage> pendingRow(
    String body, {
    SourceKind source = SourceKind.email,
    String sender = 'alerts@bank.in',
  }) async {
    final id = await db
        .into(db.rawMessages)
        .insert(
          RawMessagesCompanion.insert(
            source: source,
            externalId: 'p${seq++}',
            sender: sender,
            body: body,
            receivedAt: t0.add(const Duration(minutes: 30)),
            parseStatus: ParseStatus.pendingLlm,
            ignoreReason: const Value('no amount pattern'),
          ),
        );
    return (db.select(db.rawMessages)..where((m) => m.id.equals(id))).getSingle();
  }

  Future<RawMessage> row(int id) => (db.select(db.rawMessages)..where((m) => m.id.equals(id))).getSingle();

  setUp(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    db = AppDatabase(DatabaseConnection(NativeDatabase.memory()));
    svc = IngestionService(db);
  });
  tearDown(() => db.close());

  group('LLM fallback parsing', () {
    test('applies to the existing raw row and dedups against an SMS transaction', () async {
      await svc.ingest([
        sms('VM-HDFCBK', 'Sent Rs.250.00 From HDFC Bank A/C *4521 To SWIGGY On 12/10/26 Ref 528512345678', t0),
      ]);
      final merged = await pendingRow(
        'Hello! Your payment of INR 250.00 to Swiggy was successful. UPI transaction ID: 528512345678.',
      );
      final fresh = await pendingRow('Your a/c 4521 was charged two hundred rupees ... Rs 1,999 for Myntra order.');
      final otp = await pendingRow('Use 123456 to log in. Rs 500 cashback offer inside!');
      final hallucinated = await pendingRow('Your statement for card ending 7788 is ready.');
      final rawsBefore = (await db.select(db.rawMessages).get()).length;

      final llm = FakeLlm([
        (msgs) {
          final input = jsonDecode((msgs.single as UserMessage).text) as List;
          expect(input.map((e) => e['id']), [merged.id, fresh.id, otp.id, hallucinated.id]);
          expect(input.first['text'], contains('Swiggy'));
          return text(
            jsonEncode({
              'results': [
                {
                  'id': merged.id,
                  'isTransaction': true,
                  'amount': 250,
                  'direction': 'debit',
                  'merchant': 'Swiggy',
                  'reference': '528512345678',
                  'mode': 'upi',
                  'reason': 'payment',
                },
                {
                  'id': fresh.id,
                  'isTransaction': true,
                  'amount': '1,999',
                  'direction': 'debit',
                  'merchant': 'Myntra',
                  'accountLast4': '4521',
                  'mode': 'card',
                  'reason': 'purchase',
                },
                {'id': otp.id, 'isTransaction': false, 'reason': 'OTP/promo'},
                {'id': hallucinated.id, 'isTransaction': true, 'amount': 4200, 'direction': 'debit'},
              ],
            }),
          );
        },
      ]);

      final report = await LlmFallbackParser(db: db, ingestion: svc, client: llm, pause: Duration.zero).run();

      expect(report.merged, 1);
      expect(report.added, 1);
      expect(report.ignored, 1);
      expect(report.failed, 1);

      // No new raw rows — existing ones were updated in place.
      expect((await db.select(db.rawMessages).get()).length, rawsBefore);

      final txns = await db.select(db.transactions).get();
      expect(txns, hasLength(2)); // the SMS one + Myntra
      final swiggy = txns.firstWhere((t) => t.reference == '528512345678');
      expect((await row(merged.id)).parseStatus, ParseStatus.merged);
      expect((await row(merged.id)).transactionId, swiggy.id);
      expect(await db.sourcesOf(swiggy.id), hasLength(2));

      final myntra = txns.firstWhere((t) => t.merchant == 'Myntra');
      expect(myntra.amountMinor, 199900);
      expect(myntra.status, TxnStatus.needsReview); // AI-read → user glances once
      expect(myntra.categoryId, isNotNull);
      expect((await row(fresh.id)).parseStatus, ParseStatus.parsed);
      expect((await row(fresh.id)).transactionId, myntra.id);

      expect((await row(otp.id)).parseStatus, ParseStatus.ignored);
      expect((await row(otp.id)).ignoreReason, 'AI: OTP/promo');
      expect((await row(hallucinated.id)).parseStatus, ParseStatus.failed);

      // Idempotent: nothing pending, so a second run makes no request.
      final again = await LlmFallbackParser(db: db, ingestion: svc, client: FakeLlm([])).run();
      expect(again.sent, 0);
    });

    test('provider errors leave rows pending', () async {
      final m = await pendingRow('Rs 99 debited');
      final failing = _ThrowingLlm(const LlmException(LlmErrorKind.rateLimit, 'slow'));
      final report = await LlmFallbackParser(db: db, ingestion: svc, client: failing).run();
      expect(report.error, isNotNull);
      expect((await row(m.id)).parseStatus, ParseStatus.pendingLlm);
    });
  });

}

class _ThrowingLlm implements LlmClient {
  _ThrowingLlm(this.error);
  final LlmException error;

  @override
  String get providerId => 'x';

  @override
  Future<LlmResponse> chat({
    String? system,
    required List<LlmMessage> messages,
    List<LlmTool> tools = const [],
    int maxTokens = 4096,
  }) => throw error;

  @override
  Future<List<String>> listModels() async => const [];
}

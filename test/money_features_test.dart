import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moneytrail/data/db/database.dart';
import 'package:moneytrail/ingestion/categorizer.dart';
import 'package:moneytrail/ingestion/parser/parsed_txn.dart';

var _id = 0;

Category cat(int id, String name, {bool income = false}) =>
    Category(id: id, name: name, icon: 'other', color: 0, isIncome: income, sortOrder: id);

TxnView txn(
  int minor,
  DateTime at, {
  Category? category,
  bool transfer = false,
  TxnDirection dir = TxnDirection.debit,
  String? merchant,
}) => TxnView(
  Transaction(
    id: ++_id,
    amountMinor: minor,
    currency: 'INR',
    direction: dir,
    occurredAt: at,
    merchant: merchant,
    categoryId: category?.id,
    mode: PaymentMode.upi,
    status: TxnStatus.confirmed,
    isTransfer: transfer,
    categoryLocked: false,
    createdAt: at,
  ),
  category,
  null,
);

Budget budget(int id, int minor, {int? categoryId, bool active = true}) => Budget(
  id: id,
  categoryId: categoryId,
  amountMinor: minor,
  currency: 'INR',
  active: active,
  createdAt: DateTime(2026),
);

void main() {
  group('database', () {
    late AppDatabase db;
    setUp(() => db = AppDatabase(DatabaseConnection(NativeDatabase.memory())));
    tearDown(() => db.close());

    Future<Category> named(String n) async => (await db.allCategories()).firstWhere((c) => c.name == n);

    test('delete category moves transactions, rules and drops its budget', () async {
      final custom = await db.addCategory(name: 'Hobbies', icon: 'gaming', color: 1);
      final target = await named('Shopping');
      final t1 = await db.addManual(
        amountMinor: 1000,
        direction: TxnDirection.debit,
        at: DateTime(2026, 10, 1),
        categoryId: custom,
        merchant: 'Lego',
      );
      final t2 = await db.addManual(
        amountMinor: 2000,
        direction: TxnDirection.debit,
        at: DateTime(2026, 10, 2),
        categoryId: custom,
      );
      await db.setCategory(t1, custom, learnPattern: 'lego');
      await db.setBudget(categoryId: custom, amountMinor: 5000);
      expect(await db.countTxnsInCategory(custom), 2);

      await db.deleteCategory(custom, moveTo: target.id);

      final txns = await db.select(db.transactions).get();
      expect(txns.where((t) => t.id == t1 || t.id == t2).map((t) => t.categoryId), everyElement(target.id));
      expect(txns.where((t) => t.categoryId == custom), isEmpty);
      expect((await db.allMerchantRules()).single.categoryId, target.id);
      expect(await db.allBudgets(), isEmpty);
      expect((await db.allCategories()).any((c) => c.id == custom), isFalse);
    });

    test('Transfers and Other cannot be deleted; target must differ', () async {
      final transfers = await named('Transfers');
      final other = await named('Other');
      final food = await named('Food & Dining');
      await expectLater(db.deleteCategory(transfers.id, moveTo: food.id), throwsStateError);
      await expectLater(db.deleteCategory(other.id, moveTo: food.id), throwsStateError);
      await expectLater(db.deleteCategory(food.id, moveTo: food.id), throwsArgumentError);
      expect((await db.allCategories()).map((c) => c.id), containsAll([transfers.id, other.id, food.id]));
    });

    test('seeded categories remember their seed name after a rename', () async {
      final food = await named('Food & Dining');
      await db.updateCategory(food.id, name: 'Eating out');
      final renamed = (await db.allCategories()).firstWhere((c) => c.id == food.id);
      expect(renamed.seedName, 'Food & Dining');
      expect(AppDatabase.isProtected(await named('Other')), isTrue);
      // Built-in keywords still land in the renamed category.
      final categorizer = Categorizer(await db.allCategories(), const []);
      final parsed = ParsedTxn(
        amountMinor: 100,
        direction: TxnDirection.debit,
        occurredAt: DateTime(2026, 10, 1),
        mode: PaymentMode.upi,
        confidence: 1,
        merchant: 'Swiggy',
      );
      expect(categorizer.categorize(parsed, ''), food.id);
    });

    test('reorder writes a full ordering', () async {
      final ids = (await db.allCategories()).map((c) => c.id).toList().reversed.toList();
      await db.reorderCategories(ids);
      final ordered = await db.watchCategories().first;
      expect(ordered.map((c) => c.id), ids);
    });

    test('setBudget upserts one overall budget', () async {
      await db.setBudget(amountMinor: 1000);
      await db.setBudget(amountMinor: 2000);
      final b = await db.allBudgets();
      expect(b, hasLength(1));
      expect(b.single.amountMinor, 2000);
      expect(b.single.categoryId, isNull);
    });

    test('editing keeps source evidence; rename-all carries the rule', () async {
      final food = await named('Food & Dining');
      final a = await db.addManual(
        amountMinor: 1000,
        direction: TxnDirection.debit,
        at: DateTime(2026, 10, 1),
        merchant: 'SWIGGY LTD',
      );
      final b = await db.addManual(
        amountMinor: 2000,
        direction: TxnDirection.debit,
        at: DateTime(2026, 10, 2),
        merchant: 'swiggy ltd',
      );
      await db.setCategory(a, food.id, learnPattern: 'swiggy ltd');

      expect(await db.renameMerchant('SWIGGY LTD', 'Swiggy'), 2);
      await db.updateTxn(
        b,
        amountMinor: 2500,
        direction: TxnDirection.debit,
        occurredAt: DateTime(2026, 10, 3, 9),
        merchant: 'Swiggy',
        accountId: null,
        note: 'lunch',
      );
      final rows = await db.select(db.transactions).get();
      expect(rows.map((t) => t.merchant), everyElement('Swiggy'));
      final edited = rows.firstWhere((t) => t.id == b);
      expect(edited.amountMinor, 2500);
      expect(edited.note, 'lunch');
      expect(edited.occurredAt, DateTime(2026, 10, 3, 9));
      expect((await db.sourcesOf(b)).single.body, 'Added manually');
      final rules = {for (final r in await db.allMerchantRules()) r.pattern: r.categoryId};
      expect(rules, {'swiggy ltd': food.id, 'swiggy': food.id});
    });

    test('accounts: add cash, rename, archive', () async {
      final id = await db.addAccount(name: 'Cash', kind: AccountKind.cash, color: 1);
      await db.updateAccount(id, name: 'Wallet cash', archived: true);
      expect(await db.watchAccounts().first, isEmpty);
      final all = await db.watchAllAccounts().first;
      expect(all.single.name, 'Wallet cash');
      expect(all.single.kind, AccountKind.cash);
    });
  });

  test('v2 → v3 migration adds budgets and backfills seed names', () async {
    final dir = await Directory.systemTemp.createTemp('pckt_mig');
    final file = File('${dir.path}/db.sqlite');
    try {
      // Build a fresh DB, then strip it back to the v2 shape.
      var db = AppDatabase(NativeDatabase(file));
      await db.addCategory(name: 'Custom', icon: 'other', color: 1);
      await db.customStatement('DROP TABLE budgets');
      await db.customStatement('ALTER TABLE categories DROP COLUMN seed_name');
      await db.customStatement('PRAGMA user_version = 2');
      await db.close();

      db = AppDatabase(NativeDatabase(file));
      final cats = await db.allCategories();
      expect(cats.firstWhere((c) => c.name == 'Transfers').seedName, 'Transfers');
      expect(cats.firstWhere((c) => c.name == 'Custom').seedName, isNull);
      expect(cats.map((c) => c.name).toSet().length, cats.length, reason: 'no seed duplicated');
      await db.setBudget(amountMinor: 100);
      expect(await db.allBudgets(), hasLength(1));
      await db.close();
    } finally {
      await dir.delete(recursive: true);
    }
  });
}

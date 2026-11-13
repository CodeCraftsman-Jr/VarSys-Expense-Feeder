import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moneytrail/data/db/database.dart';
import 'package:moneytrail/ingestion/categorizer.dart';
import 'package:moneytrail/ingestion/parser/parsed_txn.dart';
import 'package:moneytrail/ingestion/parser/sms_parser.dart';
import 'package:moneytrail/ingestion/parser/text_utils.dart';

/// Regression tests built from real (masked) messages that were mis-parsed.
ParsedTxn ok(String sender, String body) {
  final r = const SmsParser().parse(
    RawInput(source: SourceKind.sms, externalId: '1', sender: sender, body: body, receivedAt: DateTime(2026, 9, 6)),
  );
  expect(r, isA<Parsed>(), reason: 'expected parse for: $body, got $r');
  return (r as Parsed).txn;
}

void main() {
  group('dates are never merchants', () {
    for (final s in [
      'Sep 06',
      'SEP 06, 2026',
      '06-Sep-26',
      '6th Sept 2026',
      '12Oct26',
      '06/09/26',
      '2026-10-12',
      '20:11:07',
      '08:01 PM',
      'September',
      'Sep 06 refund',
      'Mon, 06 Sep',
    ]) {
      test('"$s"', () {
        expect(isDateLike(s), isTrue);
        expect(cleanMerchant(s), isNull);
      });
    }

    test('real names survive, trailing dates are stripped', () {
      expect(cleanMerchant('SWIGGY'), 'Swiggy');
      expect(cleanMerchant('AMAZON 06-Sep-26'), 'Amazon');
      expect(cleanMerchant('MAYUR STORES'), 'Mayur Stores');
      expect(cleanMerchant('Marriott'), 'Marriott');
      expect(cleanMerchant('BOX8'), 'Box8');
      expect(cleanMerchant('June'), isNull);
    });
  });

  group('refund / credit templates', () {
    test('card credit "by <date> refund" has no date merchant', () {
      final t = ok('AD-HDFCBK-S', 'Rs.500 credited to HDFC Bank Card x1234 by Sep 06 refund');
      expect(t.direction, TxnDirection.credit);
      expect(t.merchant, isNull);
    });

    test('reversal "from <date> txn"', () {
      final t = ok('AD-HDFCBK-S', 'Reversal of Rs 250.00 credited to HDFC Bank Card x1234 from Sep 06 txn');
      expect(t.direction, TxnDirection.credit);
      expect(t.amountMinor, 25000);
      expect(t.merchant, isNull);
    });

    test('OneCard refund received "from <date> transaction"', () {
      final t = ok(
        'AD-ONECRD-S',
        'Refund received! Rs 250 from Sep 06, 2026 transaction has been credited to your OneCard',
      );
      expect(t.direction, TxnDirection.credit);
      expect(t.merchant, isNull);
    });

    test('multi-line credit alert with "From <date>"', () {
      final t = ok('VM-HDFCBK-S', 'Credit Alert!\nRs.250.00 credited to HDFC Bank Card x1234\nFrom Sep 06');
      expect(t.merchant, isNull);
    });

    test('date before the real merchant: picks the merchant', () {
      final t = ok('VM-HDFCBK-S', 'Credit Alert!\nRs.250.00 credited to HDFC Bank Card x1234 on Sep 06\nFrom AMAZON');
      expect(t.merchant, 'Amazon');
    });

    test('refund "for transaction dated <date> at MERCHANT"', () {
      final t = ok(
        'AD-HDFCBK-S',
        'Dear Customer, Rs.250.00 has been refunded to your HDFC Bank Credit Card XX1234 for transaction dated Sep 06 at SWIGGY',
      );
      expect(t.direction, TxnDirection.credit);
      expect(t.merchant, 'Swiggy');
    });

    test('reversed by MERCHANT on <date>', () {
      final t = ok(
        'JM-HDFCBK-S',
        'Dear Customer, Rs.1250.00 has been reversed to HDFC Bank Card XX1234 by SWIGGY on Sep 06, 2026',
      );
      expect(t.merchant, 'Swiggy');
    });
  });

  group('people', () {
    test('HDFC IMPS credit with single concatenated name is a person', () {
      final t = ok(
        'VD-HDFCBK-S',
        'Received! INR 2,000.00 in HDFC Bank A/c xx6610 On 06-09-26 For IMPS -UCHITRAM- 624912345678 Avl bal INR 12,456.00',
      );
      expect(t.merchant, 'Uchitram');
      expect(t.isPersonToPerson, isTrue);
    });

    test('IMPS debit to a single-word name is a person', () {
      final t = ok(
        'VM-KOTAKB-S',
        'Sent IMPS Rs.1,500.00 from Kotak Bank AC X5555 to UCHITRAM on 06-09-26. IMPS Ref 624912345678',
      );
      expect(t.merchant, 'Uchitram');
      expect(t.isPersonToPerson, isTrue);
    });

    test('IMPS to a business is not a person', () {
      final t = ok(
        'VM-KOTAKB-S',
        'Sent IMPS Rs.1,500.00 from Kotak Bank AC X5555 to SHREEJI TRADERS on 06-09-26. IMPS Ref 624912345678',
      );
      expect(t.isPersonToPerson, isFalse);
    });

    test('single-word UPI P2M merchant is not a person', () {
      final t = ok(
        'AX-AXISBK-S',
        'INR 99.00 debited\nA/c no. XX7890\n06-09-26\nUPI/P2M/528533334444/BLINKIT\nAxis Bank',
      );
      expect(t.isPersonToPerson, isFalse);
    });

    test('IME India remittance is person-to-person', () {
      final t = ok(
        'AD-IMEIND-S',
        'Successfully sent 15000.00 to DASHI RAM THARU. Please provide ICN: 12345678901 to the beneficiary only. -IME India',
      );
      expect(t.isPersonToPerson, isTrue);
      expect(t.institution, 'IME India');
    });
  });

  group('categories', () {
    late AppDatabase db;
    late Categorizer cat;
    late Map<int, String> names;

    setUp(() async {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      db = AppDatabase(DatabaseConnection(NativeDatabase.memory()));
      final cats = await db.allCategories();
      names = {for (final c in cats) c.id: c.name};
      cat = Categorizer(cats, const []);
    });
    tearDown(() => db.close());

    String? categoryOf(String sender, String body) => names[cat.categorize(ok(sender, body), body)];

    test('Indian Railways → Transport', () {
      expect(
        categoryOf(
          'AD-HDFCBK-S',
          'Spent Rs.30 From HDFC Bank Card x1234 At INDIAN RAILWAYS On 2026-09-06:10:11:12 Bal Rs.5000.00',
        ),
        'Transport',
      );
    });

    test('UTS ticket → Transport', () {
      expect(
        categoryOf(
          'VM-HDFCBK-S',
          'Sent Rs.15.00\nFrom HDFC Bank A/C *4521\nTo UTS MOBILE TICKET\nOn 06/09/26\nRef 624912345678',
        ),
        'Transport',
      );
    });

    test('IRCTC UPI → Transport', () {
      expect(
        categoryOf('VM-HDFCBK-S', 'Sent Rs.845.00\nFrom HDFC Bank A/C *4521\nTo IRCTC\nOn 06/09/26\nRef 624912345678'),
        'Transport',
      );
    });

    test('IME India remittance → People', () {
      expect(
        categoryOf(
          'AD-IMEIND-S',
          'Successfully sent 15000.00 to DASHI RAM THARU. Please provide ICN: 12345678901 to the beneficiary only. -IME India',
        ),
        'People',
      );
    });

    test('IMPS to single-word person → People', () {
      expect(
        categoryOf(
          'VM-KOTAKB-S',
          'Sent IMPS Rs.1,500.00 from Kotak Bank AC X5555 to UCHITRAM on 06-09-26. IMPS Ref 624912345678',
        ),
        'People',
      );
    });

    test('date-merchant refund still lands in Refunds', () {
      expect(
        categoryOf('AD-HDFCBK-S', 'Reversal of Rs 250.00 credited to HDFC Bank Card x1234 from Sep 06 txn'),
        'Refunds & Cashback',
      );
    });
  });

  group('loan app messages are never income', () {
    ParseResult p(String sender, String body) => const SmsParser().parse(
      RawInput(source: SourceKind.sms, externalId: '1', sender: sender, body: body, receivedAt: DateTime(2026, 11, 3)),
    );
    for (final (sender, body, reason) in [
      (
        'AX-KRETBE-S',
        'We have successfully received payment of Rs. 5275 towards loan availed on KreditBee. Please wait upto 24 hours for amount to reflect in loan.',
        'Loan repayment receipt',
      ),
      (
        'VM-DMISMS-S',
        'Dear Customer, we have received Rs.2729.00 for your DMI Finance loan ID ending in 6863 . The amount will reflect in your loan account on the upcoming EMI due date.',
        null,
      ),
      (
        'CP-TRCRED-S',
        "Dear Customer, We have received your loan application for Rs.10000 via True Balance App If you didn't apply, please contact us immediately.",
        'Loan offer / application',
      ),
      (
        'CP-TRCRED-S',
        'Dear Customer, As per your request your loan with application no TBLV15-50511-5325246 is approved for Rs.1747. Take Disbursement now.',
        'Loan offer / application',
      ),
      (
        'JDRFcrpP',
        'Dear 94424XX, Rs.50,000* loan is ready to be credited to your Bank A/c on 24.04.2026. Check your eligibility now http://hu2.in/x - Ramfincorp',
        null,
      ),
      (
        'VM-LXFAST',
        'Dear User, Good News! Your Wallet A/c is credited successfully with Rs. 15,000 on 16-10-2024 Check now http://Kx7.in/LXFAST/x',
        'Promotional',
      ),
      (
        'AX-FTLOXN',
        'Attention! Rs.15,000 has been credited to your wallet on 31-10-2024. Please log in to verify - http://Kx17.in/FTLOXN/x FT Loan',
        'Promotional',
      ),
    ]) {
      test(body.substring(0, 40), () {
        final r = p(sender, body);
        expect(r, isA<Ignored>(), reason: '$r');
        if (reason != null) expect((r as Ignored).reason, reason);
      });
    }

    test('the bank debit for the same repayment is still an expense', () {
      final t = ok(
        'JD-HDFCBK-S',
        'Sent Rs.5275.00 From HDFC Bank A/C *1285 To KRAZYBEE SERVICES LIMITED On 03/11/26 Ref 006556452019 Not You? Call 18002586161/SMS BLOCK UPI to 73080808',
      );
      expect(t.direction, TxnDirection.debit);
      expect(t.amountMinor, 527500);
    });

    test('a small finance bank credit is still income', () {
      final t = ok(
        'JK-SLCBNK-T',
        'Rs. 1,400 received in A/c xx1718 on 13-Jul-26 from NORTH EAST SMALL FINANCE BANK via IMPS (Ref ID: 619494385227). Avl. Bal. Rs. 1,450.00',
      );
      expect(t.direction, TxnDirection.credit);
    });
  });
}

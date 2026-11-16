import 'package:flutter_test/flutter_test.dart';
import 'package:moneytrail/core/format.dart';

void main() {
  tearDown(() => Currencies.home = 'INR');

  group('money', () {
    test('INR uses lakh/crore grouping and drops zero paise', () {
      expect(money(12345600), '₹1,23,456');
      expect(money(1234567890), '₹1,23,45,678.90');
      expect(money(25000, forceDecimals: true), '₹250.00');
      expect(money(-5050), '-₹50.50');
    });

    test('USD groups by thousands; \$ only for the home currency', () {
      expect(money(123456789, currency: 'USD'), 'USD 1,234,567.89');
      Currencies.home = 'USD';
      expect(money(123456789), '\$1,234,567.89');
      expect(money(1250), '\$12.50');
      expect(money(10000), '\$100');
      // Another dollar is told apart by its code, and INR keeps ₹ and lakhs.
      expect(money(1250, currency: 'SGD'), 'SGD 12.50');
      expect(money(12345600, currency: 'INR'), '₹1,23,456');
    });

    test('JPY has no decimals: minor units are whole yen', () {
      expect(currencyDigits('JPY'), 0);
      expect(money(1200, currency: 'JPY'), '¥1,200');
      expect(money(1234567, currency: 'JPY', forceDecimals: true), '¥1,234,567');
      expect(currencyDigits('KRW'), 0);
      expect(currencyDigits('VND'), 0);
    });

    test('KWD / BHD / OMR have three decimals', () {
      for (final c in ['KWD', 'BHD', 'OMR']) {
        expect(currencyDigits(c), 3, reason: c);
      }
      expect(money(12500, currency: 'KWD'), 'KWD 12.500');
      expect(money(12000, currency: 'KWD'), 'KWD 12');
      expect(money(1234567, currency: 'BHD', forceDecimals: true), 'BHD 1,234.567');
    });

    test('word-like symbols become codes; distinctive signs are kept', () {
      expect(money(12050, currency: 'AED'), 'AED 120.50');
      expect(money(1000, currency: 'GBP'), '£10');
      expect(money(1999, currency: 'EUR'), '€19.99');
      expect(money(150000, currency: 'PKR'), 'PKR 150,000'); // PKR has 0 digits in CLDR
      Currencies.home = 'PKR';
      expect(money(150000), 'Rs 150,000');
      expect(money(150000, currency: 'LKR'), 'LKR 1,500');
    });

    test('compact', () {
      expect(moneyCompact(12345600), '₹1.23L');
      expect(moneyCompact(4500000), '₹45K');
      expect(moneyCompact(25050), '₹251');
      Currencies.home = 'USD';
      expect(moneyCompact(450000000), '\$4.5M');
      expect(moneyCompact(120000, currency: 'JPY'), '¥120K');
    });

    test('every supported currency formats and has sane digits', () {
      for (final c in supportedCurrencies) {
        expect([0, 2, 3], contains(c.digits), reason: c.code);
        expect(money(123456, currency: c.code), isNotEmpty);
        expect(money(123456, currency: c.code), isNot(contains('null')));
      }
      expect(supportedCurrencies.map((c) => c.code).toSet(), hasLength(supportedCurrencies.length));
    });
  });

  group('defaults from locale', () {
    test('known countries map to their currency', () {
      expect(defaultCurrencyForLocale('en_IN'), 'INR');
      expect(defaultCurrencyForLocale('ar-AE'), 'AED');
      expect(defaultCurrencyForLocale('en_GB'), 'GBP');
      expect(defaultCurrencyForLocale('de_DE'), 'EUR');
      expect(defaultCurrencyForLocale('ja_JP'), 'JPY');
      expect(defaultCurrencyForLocale('zh_Hant_TW'), 'USD');
      expect(defaultCurrencyForLocale('en'), 'INR');
      expect(defaultCurrencyForLocale(null), 'INR');
    });
  });

}

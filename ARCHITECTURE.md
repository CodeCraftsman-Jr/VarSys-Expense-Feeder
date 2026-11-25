# VarSys MoneyTrail: architecture and development

How MoneyTrail works inside, for contributors. What the app does and how to set it up is in the
[README](README.md); how to send a fix is in [CONTRIBUTING.md](CONTRIBUTING.md).

## Run

```sh
flutter pub get
dart run build_runner build -d   # drift codegen
flutter run                      # phone connected with USB debugging on
flutter test                     # parser, dedup pipeline and app behavior
```

## Architecture

```
lib/
  ingestion/            source-agnostic pipeline: RawInput → parse → dedup → categorise → store
    parser/             rule-based SMS parser (bank sender ids, amounts, refs, VPAs, merchants)
    dedup/              scoring engine that merges the same payment seen via multiple sources
    categorizer.dart    learned merchant rules → structural hints → keyword lists → fallback
    sms/                Android SMS inbox reader (MethodChannel `moneytrail/sms`, see MainActivity.kt)
    email/              IMAP (enough_mail) + Gmail API sources, HTML→text, EmailSyncController
    parser/email_*      email parser: sender-domain directory, bank alerts via SMS rules, merchant receipts
  data/db/              drift schema: accounts, categories, transactions, raw_messages, merchant_rules
  features/             dashboard, activity, insights, settings, onboarding
  core/theme/           palette (validated categorical colors), typography, icon map
```

### Deduplication

Every raw message is kept in `raw_messages` and linked to the transaction it
produced or merged into, so merges are explainable and reversible.

| Signal | Effect |
|---|---|
| Same UPI ref / RRN | certain match |
| Different refs | certain non-match |
| Same account last-4 | +0.25 (different: −0.5) |
| Time proximity | +0.45 (≤5 min) … +0.1 (≤24 h) |
| Merchant token overlap | +0.2 (none: −0.1) |
| SMS ↔ email (different channels), no merchant/account conflict | +0.3 (≤30 min), +0.15 (≤3 h) |
| Same sender already reported it | −0.35 (two real ₹20 chais) |

Candidates must have the same amount **in the same currency**. A foreign spend whose alert states
the home-currency equivalent ("USD 12.50 (INR 1,045.30)") also matches a rupee-only alert for
₹1,045.30, and the merge records the conversion.

≥ 0.75 merges automatically; 0.5–0.75 creates a *possible duplicate* the user confirms.
Merchant tokens include brand aliases for the legal names banks print (BUNDL → Swiggy,
Eternal → Zomato, …). When a merchant receipt email (Swiggy, Amazon, Uber…) merges
into a bank alert, its merchant name replaces the bank's and the category is re-derived
unless the user set one.
A debit from one own account and an equal credit to another within an hour is
marked as a self-transfer and excluded from spend/income.

## Currencies

Amounts are stored as integers in each currency's minor unit (`lib/core/currency.dart`, decimals
from `intl`'s CLDR data: paise and cents, whole yen/won/dong/rupiah, fils for KWD/BHD/OMR), with an
ISO 4217 code on every transaction and account (schema v4; rows from v1.0 are INR).

- **Home currency.** Chosen at onboarding (defaulted from the phone's region) and in
  Settings → Money → Currency. Existing installs keep INR. Totals, budgets, charts and notifications
  use it. Budgets remember their currency and pause if you switch.
- **Foreign transactions.** MoneyTrail has no server and never fetches exchange rates. A message that
  states the home-currency equivalent is stored with both amounts and counts at once. Otherwise the
  transaction keeps its own currency, is shown with "not in totals", and you add what the bank
  charged (or a rate) from the transaction; until then it is left out of totals rather than guessed.
  The dashboard says how many are waiting.
- **Parsing.** Markers are read with the amount: `Rs`/`₹`/`INR`, ISO codes before or after the
  number, `$ US$ S$ A$ C$ NZ$ R$ € £ ¥ ₩ ₱ ₫ ฿ ₦ ₺ ৳ RM Rp KSh`. A bare `$` or `Rs` means the home
  dollar/rupee when it is one (USD/INR otherwise). Alerts from senders MoneyTrail doesn't know still parse
  at a lower confidence and are marked for review.
- **Supported:** INR, AED, SAR, QAR, KWD, OMR, BHD, SGD, MYR, USD, GBP, CAD, AUD, NZD, EUR, BDT, PKR,
  LKR, NPR, IDR, PHP, VND, THB, NGN, KES, ZAR, BRL, MXN, TRY, JPY, KRW.

## Email

Settings → Sources → Email → Connect. MoneyTrail searches the INBOX since the chosen
import window (1/3/6/12 months, then incrementally with a 1-day overlap, max 400
messages per sync) for mail from known bank / card / UPI / merchant domains or with
payment words in the subject, downloads only those, converts HTML to text and runs
them through the same parse → dedup → categorise pipeline as SMS. Network and MIME
work runs in a background isolate. Settings live in SharedPreferences (`email.*`);
the password only in the Android keystore (`SecretStore`). Inspect shows every
email and why it was parsed, merged or ignored.

App-password setup for each provider is in the README (*Connect your email*).

### Gmail sign-in (OAuth, optional)

"Sign in with Google" (Gmail REST API, `gmail.readonly`) only appears when the build
has an OAuth client id. One-time Google Cloud setup:

1. console.cloud.google.com → create a project → *APIs & Services → Library* → enable **Gmail API**.
2. *OAuth consent screen*: External, app name "MoneyTrail", add scope
   `https://www.googleapis.com/auth/gmail.readonly`, add your Google account as a **test user**
   (Testing mode is enough for personal use; `gmail.readonly` is a restricted scope, so
   publishing would need Google verification).
3. *Credentials → Create credentials → OAuth client ID → Android*: package name
   `com.varsys.moneytrail`, SHA-1 of the signing key. For debug builds:
   ```sh
   keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android -keypass android
   ```
   (Release builds need the release key's SHA-1 as a second Android client.)
4. *Create credentials → OAuth client ID → Web application* (no redirect URIs needed). Android's
   Credential Manager uses this one as the *server client id*.
5. Build with the **Web** client id:
   ```sh
   flutter run --dart-define=GOOGLE_OAUTH_CLIENT_ID=1234567890-abc.apps.googleusercontent.com
   ```

## Real-time SMS alerts (Android)

`SmsAlertReceiver.kt` listens for `SMS_RECEIVED` (permission `RECEIVE_SMS`, asked together with
`READ_SMS`). If a message comes from a known bank DLT sender (`VM-HDFCBK`, `AD-ICICIT-S`, not
`-P` promos) and has a completed debit/credit verb plus an amount, MoneyTrail posts a notification
such as *"₹250 debited · HDFC"* (or *"USD 12.50 debited · HDFC"* for a spend abroad) on the
**Transaction alerts** channel. The notification says "Captured. Your team sorts it on the web." The
receiver reads the home currency from `flutter.currency.home` and stores no data. Tapping opens
MoneyTrail, which syncs SMS on resume. Turn alerts off in Settings → SMS → *Instant alerts* (pref
`sms.alerts`, read natively as `flutter.sms.alerts`).
Android 13+ also needs the notification permission, which MoneyTrail asks for once.

## Security

- **Encrypted database.** `moneytrail.sqlite` is a SQLCipher 4 database (AES-256). `package:sqlite3` bundles
  the SQLCipher build instead of SQLite through `hooks: user_defines: sqlite3: source: sqlcipher` in
  `pubspec.yaml` (it also applies to `flutter test` on the desktop VM). A random 256-bit key is created
  on first run and kept in the Android keystore via `flutter_secure_storage`; it is used as a raw key,
  so opening costs no key derivation (`lib/data/db/db_encryption.dart`).
- **Upgrading from a plaintext install** happens once, on the first open: the plaintext file is
  exported into `moneytrail.sqlite.enc-tmp` with `sqlcipher_export`, per-table row counts, `user_version` and
  integrity checks are compared, the files are swapped by rename, the result is verified again, and only
  then is the plaintext copy (`moneytrail.sqlite.plain-bak`) deleted. Any failure keeps the app on the
  plaintext database and it retries on the next start. Every step logs with `[moneytrail-db]`. If the key is
  ever lost (keystore wiped) the unreadable file is kept aside as `moneytrail.sqlite.unreadable-<time>` and a
  new database is started.
- **No backups.** Android cloud backup and device-to-device transfer are disabled. The data and key
  stay on the phone. Use the app's export to move data.
- **App lock** (Settings → Security, off by default): fingerprint / face / screen lock on a cold start
  and after more than 2 minutes in the background. Turning it on requires one successful unlock; if the
  phone's screen lock is later removed, the app lock switches itself off instead of locking you out.
- **Hide in recent apps** sets `FLAG_SECURE` (blank app-switcher thumbnail, no screenshots), applied
  natively before the first frame.

## Release builds

```sh
flutter build apk --release      # R8 minify + resource shrinking (android/app/proguard-rules.pro)
```

Without `android/key.properties` the release APK is signed with the debug key, which is fine for
sideloading. For a proper upload key (keep it safe and never commit it; `*.jks` and
`key.properties` are gitignored):

```sh
keytool -genkey -v -keystore ~/moneytrail-upload.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

then create `android/key.properties`:

```properties
storePassword=<store password>
keyPassword=<key password>
keyAlias=upload
storeFile=C:/Users/<you>/moneytrail-upload.jks
```

`storeFile` is resolved relative to `android/app/` unless absolute. Note that an APK signed with a new
key can't be installed over one signed with the debug key; uninstall first, which deletes the data,
so export it first).

### Icon and splash

The logo sources are `assets/branding/source/moneytrail-app-icon.png` (white "M" mark on
MoneyTrail blue) and `moneytrail-logo-horizontal.png` (mark plus the VarSys MoneyTrail wordmark).
`python tool/gen_brand_assets.py` (needs Pillow) lifts the white mark out as an alpha mask and
writes the Android adaptive icon (PNG foreground, flat blue background, `<monochrome>` layer for
Android 13+ themed icons), the notification small icon `@drawable/ic_stat_varsys` (white on
transparent, kept through resource shrinking by `res/raw/keep.xml`), legacy PNGs, the splash images,
`assets/branding/app_icon.png` (drawn in-app by `BrandMark`), the iOS AppIcon (default, dark and tinted iOS 18
appearances) and previews on light and dark home screens in `assets/branding/previews/`. The splash is
the icon disc on paper in light mode and on ink in dark mode (Android 12+ system splash and the older
launch window; iOS uses the `LaunchBackground` named colour).

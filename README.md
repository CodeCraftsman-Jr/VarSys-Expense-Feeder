<p align="center"><img src="assets/branding/source/moneytrail-logo-horizontal.png" width="480" alt="VarSys MoneyTrail"></p>

# VarSys MoneyTrail

VarSys MoneyTrail reads the bank, card and UPI alerts on a member's phone and, from phase 2 of
the plan, sends them to Joint Journey so a household can see whose money paid for each spend.
Architecture: `docs/plan/feed-architecture-plan.md`.

**Origin and license.** MoneyTrail is a modified version of
[Pckt](https://github.com/pritam-ravani/pckt), copyright its original author, and is distributed
under the same GNU General Public License version 3 (see `LICENSE`). Changes from Pckt: the app
name, Android application id `com.varsys.moneytrail`, HTTPS-only networking, an About screen, and
the Joint Journey feed described in the plan. The sections below describe MoneyTrail and retain
Pckt references where they explain the project's origin or shared features.

---

<h1 align="center">Pckt</h1>

<p align="center"><b>An open-source finance tracker that imports SMS and email alerts.</b></p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/pritam-ravani/pckt" alt="License: GPL-3.0"></a>
  <img src="https://img.shields.io/badge/platform-Android%207%2B-3DDC84?logo=android&logoColor=white" alt="Platform: Android 7+">
  <a href="https://github.com/pritam-ravani/pckt/releases/latest"><img src="https://img.shields.io/github/v/release/pritam-ravani/pckt" alt="Latest release"></a>
  <a href="https://github.com/pritam-ravani/pckt/stargazers"><img src="https://img.shields.io/github/stars/pritam-ravani/pckt?style=flat" alt="GitHub stars"></a>
</p>

<p align="center"><img src="assets/branding/ad/pckt-ad.gif" width="720" alt="Pckt in 30 seconds"></p>

<p align="center">
  <a href="https://github.com/pritam-ravani/pckt/releases/latest"><img src="https://img.shields.io/badge/Download-APK-6D5DF6?style=for-the-badge&logo=android&logoColor=white" alt="Download the APK" height="44"></a>
  <br><sub>Free download · Android 7+</sub>
</p>

<p align="center">
  <img src="assets/branding/screens/activity.png" width="250" alt="Activity: transactions read from bank SMS">
  <img src="assets/branding/screens/categories.png" width="250" alt="Home: budget and where the money went">
</p>

MoneyTrail reads bank, card and UPI alerts arriving on your phone by SMS and email, turns them into
transactions, merges copies, and sorts each one into a category. Everything stays in an encrypted
database on your phone.

Built for India first (Indian bank SMS formats, UPI references and VPAs, NACH/IMPS/NEFT, lakh/crore
grouping), and works with 30+ currencies: pick your home currency, and spends abroad keep theirs.

## How it works

Banks and merchants often send payment alerts by SMS or email. MoneyTrail reads those messages on
your phone and stores the resulting transactions in its encrypted database.

- **Messages in, transactions out.** A rule-based parser understands Indian bank alerts (sender
  IDs, amounts, account last-4, UPI refs, merchants) and reads amounts in any currency ("USD 12.50",
  "£8.40", "AED 120.00"), so generic card and bank alerts from elsewhere parse too, flagged for a
  quick review.
- **One payment, one row.** The same ₹450 Swiggy order shows up as a bank SMS, a bank email and a
  Swiggy receipt. A scoring dedup engine (same reference, account, time, merchant, channel) merges
  them, and you can see why each merge happened and undo it. Transfers between your own accounts are
  recognised and kept out of spend.
- **Learns your categories.** When you fix a category, it becomes a merchant rule.

## How it compares

| | **Pckt** | **Oinkoin** | **Axio** (ex-Walnut) | **YNAB / Monarch** |
|---|---|---|---|---|
| Price | Free | Free, paid Pro | Free (makes money on loans / credit) | Subscription, about US$100/year |
| Source | Open (GPL-3.0) | Open (GPL-3.0) | Closed | Closed |
| How transactions get in | **Automatic** from SMS + email, share sheet | Typed in by hand | Automatic from SMS | Bank sync (mostly US/EU banks) |
| SMS + email dedup | ✓ | — | — | n/a |
| Where data lives | Your phone, encrypted (SQLCipher) | Your phone | Their cloud | Their cloud |
| Account needed | No | No | Yes | Yes |
| Budgets, recurring, export | ✓ | ✓ (recurring and backup are Pro) | Budgets, bill reminders | ✓ |
| Platforms | Android (iOS via Shortcuts, untested) | Android, Linux, Windows | Android, iOS | Web, iOS, Android |

**Oinkoin** is another open-source, offline finance tracker. Users enter transactions by hand, and
backup and recurring records are Pro features. MoneyTrail imports transaction alerts and includes
backup and recurring records at no charge.

YNAB and Monarch sync through bank aggregators and require a subscription. Some Indian apps read SMS
and also offer lending or credit products. MoneyTrail parses messages on the phone and stores its
data in the encrypted database.

*Comparison based on each app's public pages as of October 2026; pricing and features change.*

## Features

- Automatic import from SMS (history + real-time alerts) and email (IMAP app passwords for Gmail,
  Outlook, Yahoo, Zoho or any server; optional Gmail OAuth)
- Share any message or receipt into Pckt, plus a `pckt://ingest` link for iOS Shortcuts
- Dashboard, activity feed, insights charts, budgets per category, recurring payment detection
- A home currency (31 to choose from, defaulted from the phone's region) for totals and budgets;
  transactions and accounts keep their own currency, with correct decimals (¥1,200,
  KWD 12.500) and Indian grouping only for rupees
- Edit transactions, manage accounts and categories; every source message is inspectable
- Encrypted database, optional biometric app lock, hidden from screenshots and recents, no cloud
  backup; CSV export and full JSON backup/restore

## Install

1. Download `pckt-v*.apk` from [Releases](https://github.com/pritam-ravani/pckt/releases).
2. Open it on your phone and allow installing from your browser/files app.
3. Grant SMS access when Pckt asks. It reads your inbox once, then keeps up as new alerts arrive.

## Setup guides

<details>
<summary><b>Connect your email</b></summary>

Settings → Sources → Email → Connect. Pckt only downloads mail from known bank, card, UPI and
merchant senders (or with payment words in the subject) and runs it through the same pipeline as
SMS, so an email and its SMS become one transaction. The password is kept in the Android keystore.

| Provider | Steps | Server |
|---|---|---|
| Gmail | Turn on 2-Step Verification (myaccount.google.com/security) → myaccount.google.com/apppasswords → create "Pckt" → paste the 16 characters | imap.gmail.com:993 |
| Outlook / Hotmail | Two-step verification → Advanced security options → app password. Microsoft is phasing out password IMAP for personal accounts; if it fails, forward alerts to Gmail/Zoho | outlook.office365.com:993 |
| Yahoo | login.yahoo.com/account/security → Generate app password | imap.mail.yahoo.com:993 |
| Zoho | Enable IMAP access in Mail settings; with 2FA create an app-specific password | imap.zoho.in:993 (imap.zoho.com outside India) |
| Other | Any IMAP server, SSL (993) or STARTTLS (143) | — |

"Sign in with Google" appears only in builds made with your own OAuth client id; see
[ARCHITECTURE.md](ARCHITECTURE.md#gmail-sign-in-oauth-optional).

</details>

<details>
<summary><b>Currencies</b></summary>

- **Home currency.** Chosen at onboarding (defaulted from the phone's region) and in
  Settings → Money → Currency. Existing installs keep INR. Totals, budgets, charts and notifications
  use it. Budgets remember their currency and pause if you switch.
- **Foreign transactions.** Pckt has no server and never fetches exchange rates. A message that
  states the home-currency equivalent is stored with both amounts and counts at once. Otherwise the
  transaction keeps its own currency, is shown with "not in totals", and you add what the bank
  charged (or a rate) from the transaction; until then it is left out of totals rather than guessed.
  The dashboard says how many are waiting.
- **Supported:** INR, AED, SAR, QAR, KWD, OMR, BHD, SGD, MYR, USD, GBP, CAD, AUD, NZD, EUR, BDT, PKR,
  LKR, NPR, IDR, PHP, VND, THB, NGN, KES, ZAR, BRL, MXN, TRY, JPY, KRW.

</details>

<details>
<summary><b>Instant alerts</b></summary>

When a bank SMS arrives, MoneyTrail posts a notification such as *"₹250 debited · HDFC"*. The
notification says "Captured. Your team sorts it on the web." Tapping opens MoneyTrail, which syncs
SMS when it resumes. Turn alerts off in Settings → SMS → *Instant alerts*.

</details>

<details>
<summary><b>Share to Pckt & iOS Shortcuts</b></summary>

Any text can be fed through the normal pipeline (parse → dedup → categorise → store) as source
`shortcut`; a snackbar says whether it was added, matched an existing transaction or ignored.

- **Android share sheet:** long-press a bank SMS → Share → Pckt.
- **Link:** `pckt://ingest?text=<url-encoded message>&sender=<url-encoded sender>` (`sender` is
  optional; without it the bank is guessed from the text). Works on Android and iOS.

iOS gives apps no SMS access, but a Shortcuts automation can forward each bank message:

1. Shortcuts → **Automation** → **+** → **Message**. *Message Contains*: `debited` (make a second
   automation for `credited`, and for `spent` if your card SMS use it). Choose **Run Immediately**.
2. Add **URL Encode** → input: *Shortcut Input* → **Content** (tap the variable to pick it).
3. Add a second **URL Encode** → input: *Shortcut Input* → **Sender**.
4. Add **Text**: `pckt://ingest?text=` *URL Encoded Text (1)* `&sender=` *URL Encoded Text (2)*.
5. Add **Open URLs** with that Text.

Each matching message then opens Pckt briefly and shows what was recorded. Sharing the same message
twice is a no-op (content-hashed id), and a message that also arrives by email is merged by dedup.

</details>

<details>
<summary><b>Export & backup</b></summary>

Settings → Data:

- **Export transactions (CSV):** date, amount, direction, merchant, category, account, mode,
  reference, note, sources, currency, converted amount and its currency (amounts use the currency's
  decimals); UTF-8 with BOM so Excel shows symbols and names correctly.
- **Back up everything:** a JSON dump of every table (accounts, categories, transactions, raw
  messages, merchant rules and anything added later) with format and schema versions.
- **Restore from backup:** validates the file (format, schema version not newer than the app,
  required tables), shows what it contains, and after confirmation replaces all data in a single
  DB transaction (nothing changes if anything fails). Backups from v1.0 restore with every amount in
  INR.

Files go out through the share sheet or a *Save to device* dialog.

</details>

## Contributing

Issues and pull requests are welcome, especially **SMS and email formats from banks Pckt doesn't
read yet**. See [CONTRIBUTING.md](CONTRIBUTING.md). Please remove real names, account numbers and
references from any sample message you share.

## License

[GPL-3.0](LICENSE). You can use, study, change and share Pckt. If you distribute a modified
version, you must publish its source under the same license.

## Roadmap

- [x] Phase 1: app shell, theme, DB, dashboard, activity, insights, manual entry
- [x] Phase 2: Android SMS import + parser, dedup, auto-categorisation, account discovery
- [x] Phase 3: Email: IMAP with app passwords (Gmail, Outlook, Yahoo, Zoho, any IMAP) + optional
      Gmail OAuth (`gmail.readonly`); email parser feeding the same pipeline, SMS↔email dedup
- [x] Phase 4: optional LLM features (removed; the phone no longer sends finance data to AI providers)
- [x] Phase 5: budgets, recurring payments, editing, SQLCipher encryption, app lock, iOS Shortcuts /
      share bridge, real-time SMS alerts, CSV export & JSON backup
- [x] v1.0.1: multi-currency: home currency, per-transaction and per-account currency, foreign card
      spends, currency-agnostic SMS amounts for alerts from outside India
- [ ] Next: bank sender lists and formats for the Gulf, UK, US and Singapore, iOS testing, Qualcomm
      NPU opt-in, F-Droid

## Development

```sh
flutter pub get
dart run build_runner build -d   # drift codegen
flutter run                      # phone connected with USB debugging on
flutter test
```

How the parser, dedup engine, database, encryption and release builds work is in
[ARCHITECTURE.md](ARCHITECTURE.md).

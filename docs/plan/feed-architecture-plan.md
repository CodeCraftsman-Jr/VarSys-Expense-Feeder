# Transaction feed for Joint Journey: architecture plan

Status: revision 4. Review 1 (29 findings) and review 2 (17 partial plus 23 new findings)
are both applied; section 18 maps every finding. No further review rounds. Revision 4 removes the
configurable funding rules (section 19). Date: 2026-11-12.
App name: VarSys MoneyTrail (decided 2026-11-12). Short label on the phone: MoneyTrail.
Android application id: `com.varsys.moneytrail` (VarSys convention, as `com.varsys.jointjourney`).

## 0. Glossary

| Term | Meaning |
|---|---|
| JJ | Joint Journey, the VarSys household ledger product (`Joint-Journey` repo). |
| Alpha, beta, gamma | JJ team roles from the auth-service. Alpha owns the team; beta edits; gamma creates and requests edits. |
| Phone owner | The signed-in member whose phone read the message. |
| Feed row | One row in `ledger.feed_rows`: one transaction as the phone app recorded it (the phone may already have merged an SMS and an email copy into it). |
| Event | One real-world money movement on one side (a debit or a credit). Feed rows from several phones can describe one event. |
| Spend | A debit event that leaves the team: a payment to a merchant or a non-member. |
| Internal transfer | A debit by one member and the matching credit to another member: two events joined by a pair. |
| Holder | The member whose account holds some money. |
| Funder | The member whose money it originally was. |
| Lot | "Holder H has X rupees that belong to funder F". Lots are computed by the replay, never typed in. |
| Allocation | The decision that part of a consumer event used a given lot or the holder's own money. |
| Pin | An allocation an alpha decided; the replay must honour it. |
| Spender | The member an expense row is attributed to (`ledger.expenses.member_user_id`). |
| UTR / RRN | The 12-digit reference of a UPI or IMPS payment; the same value appears on the sender's and the receiver's alert. |
| VPA | A UPI address such as `name@bank`. |

## 1. The question this answers, goals and non-goals

The user question: for every rupee the team spent, whose money was it? When P1 sends 1000 to P2 and
P2 spends it, the spend is P1's, not P2's. When P2 spends money P2 already had, it is P2's.

Goals
- Each member's phone sends its bank transactions to JJ automatically.
- Internal transfers never count as spending.
- Spends are attributed to the member whose money was used, with the funding link visible.
- The server suggests funding links with one fixed rule (received first); alpha members accept,
  change or reject every link. There are no configurable funding rules.

Non-goals (v1)
- Exact account balances or net worth.
- Agreed splitting of one spend across members (a settle-up feature).
- iOS.
- Email import before phase 5.

## 2. Starting point

Source: `VarSys-Expense-Feeder`, a fork of Pckt 1.0.1 (build 3), Flutter, Android 11+, remote
`CodeCraftsman-Jr/VarSys-Expense-Feeder`.

### 2.1 What Pckt already does

- Reads bank SMS (with the SMS inbox row id as `externalId`, `lib/ingestion/sms/sms_source.dart`)
  and email, and parses them into `ParsedTxn` (`lib/ingestion/parser/parsed_txn.dart`): amount in
  minor units, direction, occurredAt, mode, merchant, counterparty, accountHint, reference,
  institution, isPersonToPerson, transferHint, confidence, currency and converted amount.
- Modes `upi, card, netbanking, neft, imps, rtgs, atm, wallet, cash, other`; source kinds
  `sms, email, manual, shortcut` (`lib/data/db/tables.dart`).
- Merges copies of one payment on the phone before storing it (`DedupEngine` in
  `lib/ingestion/ingestion_service.dart` around lines 190-210): an SMS and its email copy become
  one transaction, and every raw message records which transaction it merged into.
- Detects self transfers between the owner's own accounts (`_detectSelfTransfer`,
  `ingestion_service.dart` line 361).
- Has an SMS broadcast receiver (`SmsAlertReceiver`, `AndroidManifest.xml` lines 62-70) that only
  posts a notification, and WorkManager wiring used only for model downloads (lines 76-81).
- Merchant-rule categorizer, SQLCipher storage, optional LLM features.

### 2.2 Gaps and changes (assigned to phases in section 14)

| Item | Current behaviour | Change | Phase |
|---|---|---|---|
| UPI note | Not extracted | Extract the remark into a new `note` field | 3 |
| Counterparty VPA | Dropped when a name is found (`sms_parser.dart` near line 189) | Keep both | 3 |
| Transfer kind | One `transferHint` flag for self transfer and card bill (near line 347) | Add `transferKind` (`none`, `self`, `card_bill`, `p2p`) | 2 |
| Reversals and failed payments | Parsed as ordinary credits | Flag `isReversal` with the reversed reference when present | 4 |
| Background ingest | Receiver only notifies; SMS read when the app opens (`home_shell.dart` line 31) | Extend the receiver to enqueue an ingest WorkManager job; add a periodic sync job | 2 |
| Stable row id across parser upgrades | `resetSource` deletes and recreates transactions (`lib/providers.dart:196`, `database.dart:360`) | Upload key built from the message, not from the transaction id (4.2) | 2 |
| Cleartext HTTP | Allowed (`AndroidManifest.xml` line 19) | Off | 1 |
| About and licenses screen | None | Add | 1 |
| SMS time | Always the receive time; the body time is not read | Keep; stored with `occurred_at_source = received` | none |
| Account hint | 3 or 4 digits | Keep as text | none |

### 2.3 License constraint

Pckt is GPL-3.0, copyright its original author.
- The fork stays GPL-3.0; original copyright and license notices stay (README, LICENSE, the new
  About screen).
- Installing the app on other people's phones is distribution; recipients are entitled to the
  corresponding source. The fork's GitHub repository is published, or a written offer ships with
  the APK.
- The JJ API talks to the app over HTTP and is a separate program; GPL (not AGPL) does not reach it.
- If this is unacceptable, the alternative is a clean-room parser using Pckt only as a behavioural
  reference.

## 3. Components

```
Phone (Flutter app, one per member)
  SMS (email from phase 5) -> parser -> phone-side merge (DedupEngine) -> local encrypted DB
  -> outbox (per target team) --HTTPS, Bearer session token, X-Device-Id, X-Expected-Team-Id-->

JJ API (apps/api, Next.js)
  POST   /api/feed/devices                              register device
  DELETE /api/feed/devices/{id}                         revoke device
  POST   /api/feed/rows                                 insert-or-return-existing, per-row results
  POST   /api/feed/rows/{client_message_id}/annotations phone edits
  DELETE /api/feed/rows/raw-text                        purge own raw text
  GET    /api/feed/review                               review queue
  POST   /api/feed/review/{id}/decision                 link, change split, keep separate
  POST   /api/feed/review/accept                        accept several suggestions (alpha)
  POST   /api/feed/review/{id}/comments                 suggestion comment (any role)
  GET/PUT /api/feed/settings                            feed settings (PUT: alpha only)
  POST   /api/feed/jobs/nightly                         scheduled job (service secret)
  -> Postgres, ledger schema (section 4) -> ledger.expenses (existing)
```

### 3.1 Authentication and devices

- The app signs in to the central auth-service (Better Auth) and keeps the session token in
  `flutter_secure_storage`.
- Every call sends `Authorization: Bearer <token>`. The JJ API already supports this:
  `apps/api/src/lib/auth.ts` forwards the cookie or authorization header to
  `auth-service /api/auth/tenant-context`, which returns `userId`, `teamId` and `role`, derived on
  the server, and caches the result for 30 s per header.
- Device registration: on first sign-in the app creates a random `device_id`, stores it in secure
  storage, and registers it. Every feed call sends `X-Device-Id`; unknown or revoked devices get
  403 `DEVICE_REVOKED` on feed routes.
- Revoking the device's Better Auth session from JJ needs an auth-service endpoint that revokes a
  given session for an alpha of the same team. Checked in phase 1 (2026-11-12): it does not exist;
  Better Auth's `revoke-session` only revokes the caller's own sessions. Until one is added,
  revocation covers feed routes only, and the member can sign the device out from their own account.
- Network: `usesCleartextTraffic` off; HTTPS only.
- 401 handling: the app retries once after 5 s before asking the user to sign in again, because an
  auth-service timeout also returns 401 (`auth.ts` returns null on fetch failure). The outbox
  pauses during sign-in; no row is dropped.

### 3.2 Team targeting

- Tenant-context resolves the team from the session's active organization and the verified team
  membership inside it; a client cannot choose a team per request.
- Each bank account on the phone maps to one target team (default: the active team when the
  account is first seen). Each outbox row stores that `team_id`.
- One sync cycle processes one team at a time and sends `X-Expected-Team-Id`. On 409
  `TEAM_MISMATCH` the app switches the active organization through the auth-service, waits 30 s
  (the session cache), and retries. At most 3 attempts per team per cycle; after that the rows stay
  queued with the error shown, and the next cycle tries again. Teams are visited in a fixed order,
  so a phone with accounts in two teams switches at most twice per cycle.

### 3.3 What leaves the phone

Per feed row: `client_message_id` (4.2), `message_ids` (the inbox ids or email Message-IDs the
phone merged into this row), amount and currency, converted amount and currency when present,
direction, `occurred_at`, `occurred_at_source`, bank, account hint, mode, `transfer_kind`, UTR/RRN
(normalized to digits), counterparty VPA and name, merchant, UPI note (phase 3), `is_reversal` and
`reverses_reference` (phase 4), phone-side category name (a hint), parser confidence, source kinds
merged, `app_version`, `parser_version`.

Never sent: OTPs and non-financial messages. The parser rejects them on the phone, and only parsed
transactions are uploaded.

Raw text: sent only if the member opts in. It is purgeable at any time and by default kept 90 days
(section 9). Both ship in phase 2, the first phase that uploads.

Private rows: an account or transaction marked private sends only `client_message_id`, amount,
direction, `occurred_at`, account hint and `private = true`. The server treats it as the holder's own
money and never shows merchant or note to others, which keeps lot balances correct without exposing
detail. The toggle ships in phase 2.

LLM fallback: Pckt can send unparsed messages to a cloud LLM the member configured. It is off by
default in this app; when enabled, the in-app privacy text says this is the one case where raw text
goes to a third party.

### 3.4 Sync

- Local outbox entries (rows and annotations) with `team_id`, attempt count and last error.
- Background: the extended SMS receiver enqueues a one-time WorkManager ingest-and-sync job; a
  periodic WorkManager job (network required, exponential backoff) syncs anything left.
- Batches of up to 100 rows. Per-row result: `{ client_message_id, id, status: accepted |
  already_received | rejected | client_outdated, reason? }`. The server `id` is stored locally.
- After each successful batch the device sends `synced_through` (the receive time of the newest
  message it has fully processed).
- Phone edits after upload are annotations keyed by `(device_id, client_seq)` and addressed by
  `client_message_id`, never re-sends.

### 3.5 Distribution and updates

- Google Play restricts SMS permissions to default SMS apps and approved exceptions; distribution is
  through the VarSys Store (sideload) only.
- Gmail (`gmail.readonly`, restricted) is limited to 100 manually added test users without Google
  verification; IMAP with an app password is the fallback (phase 5).
- Every row carries `app_version` and `parser_version`; the API rejects rows below
  `feed_team_settings.min_parser_version` with `client_outdated`. The app checks the VarSys Store for
  updates on start.
- Versioning follows the workspace mobile Version Sync rules.

## 4. Data model (JJ Postgres)

All new tables are JJ-owned in the `jointjourney` schema (the `ledger` schema is shared with other
products; migration 1a shipped there on 2026-11-12 as
`Joint-Journey/scripts/db-pull/postgres/2026-11-12-feed-devices.sql`), created by explicit migrations (14.1) that also
enable RLS, write each table's policies, and add the activity trigger where named. They have
`id bigint generated always as identity` and `team_id text not null` (FK to the auth team table).
Non-negative money columns use the existing domain `jointjourney.money_amnt`
(numeric(12,2), `>= 0`); direction is a separate column, never a sign.

### 4.1 `feed_devices`

`id`, `team_id`, `user_id`, `device_id` (unique per team), `label`, `app_version`, `synced_through`,
`registered_at`, `last_seen_at`, `revoked_at`, `revoked_by`. The app makes a new `device_id` at each
sign-in and deletes it at sign-out, so a shared phone never carries one member's id into another's
account, and a revoked phone rejoins only after the member signs in again with their password.
Devices are revoked, never deleted; a trigger keeps identity columns fixed and revocation permanent.

### 4.2 `feed_rows`

`id`, `team_id`, `user_id` (phone owner), `device_id`, `client_message_id`, `message_ids` (text[]),
`amount`, `currency`, `converted_amount`, `converted_currency`, `direction`, `occurred_at`,
`occurred_at_source`, `bank_name`, `account_hint`, `mode`, `transfer_kind`, `reference`,
`counterparty_vpa`, `counterparty_name`, `merchant`, `note`, `category_hint`, `is_reversal`,
`reverses_reference`, `raw_text`, `source_kinds`, `parser_confidence`, `app_version`,
`parser_version`, `private`, `event_id` (FK `feed_events`, added in migration 2b), `status`,
`received_at`.

`client_message_id` = sha256 of the sorted `message_ids` plus a random per-install id (kept across
sign-outs, never sent on its own). It identifies the messages, so it survives `resetSource` and
parser upgrades, and two phones of one member never collide. Unique `(team_id, user_id,
client_message_id)`: the device id changes at every sign-in, so keying on it would re-upload a
member's history after each sign-in. Its only job is to make retransmission harmless.

Shipped 2026-11-12 (migration `2026-11-12-feed-rows.sql`): amounts are stored as exact
`amount_minor` plus ISO `currency` (money_amnt is numeric(12,2) and would round three-decimal
currencies; conversion happens at write-through); `transfer_hint` carries the phone's transfer flag
until `transfer_kind` is extracted; `raw_text`, `private` and the team view arrive with the
raw-text and privacy slice. The phone keeps no separate outbox queue: the outbox is every SMS or
email transaction without an upload record for the team (`lib/feed/feed_outbox.dart`).

Mutable columns, and only these: `status`, `event_id`, `private` (through an annotation),
`raw_text` (purge only). Everything else is fixed after insert.

### 4.3 `feed_annotations`

`id`, `team_id`, `feed_row_id`, `device_id`, `client_seq`, `kind` (`category_hint`, `note`,
`private`, `delete_request`), `value`, `created_at`. Unique `(device_id, client_seq)`. Applied in
order under the team lock. `private` sets `feed_rows.private`. A delete request, or a private mark
on a row whose event already produced an expense, becomes a review item.

### 4.4 `feed_events`

One money movement on one side. `id`, `team_id`, `direction`, `kind` (`spend`, `transfer_out`,
`transfer_in`, `self_transfer`, `card_bill`, `wallet_topup`, `atm`, `income`, `refund`,
`reversal`, `unknown`), `amount`, `occurred_at`, `order_key` (6.2), `holder_user_id`, `bank_name`,
`account_hint`, `reference`, `category_id` (5.4), `reverses_event_id`, `reversed_amount`,
`matched_expense_id` (5.3), `status` (`open`, `attributed`, `ignored`, `partly_reversed`,
`reversed`).

Holder: the phone owner; for an account in `member_identities` with a `default_spender_user_id`
(a joint account or add-on card), that member.

### 4.5 `member_identities`

`id`, `team_id`, `user_id`, `kind` (`vpa`, `phone`, `account`, `card`), `value`,
`default_spender_user_id`, `verified_at`, `verified_by`. Unique `(team_id, kind, value)`.
Verified automatically only when seen on that member's own phone as their own account or VPA;
otherwise an alpha confirms. Unverified identities never trigger automatic pairing.

### 4.6 `feed_pairs`

`id`, `team_id`, `debit_event_id`, `credit_event_id` (null for a one-sided pair),
`counterparty_user_id`, `match_method` (`reference`, `amount_time`, `one_sided`, `manual`),
`status` (`proposed`, `accepted`, `rejected`), `decided_by`, `decided_at`.
Partial unique indexes on `debit_event_id` and on `credit_event_id` where status is not `rejected`.
Pairs are inputs to the replay, decided by people or by the reference rule.

### 4.7 `feed_lots` (replay output)

`id`, `team_id`, `lot_key` (unique per team: `source_event_id:funder_user_id`), `holder_user_id`,
`funder_user_id`, `source_event_id` (the transfer-in, ATM or excess event that created it),
`parent_lot_id`, `root_opened_at` (from the root lot; shown as the lot's age in review), `kind`
(`bank`, `cash`),
`amount`, `remaining` (as of the last replay, display only), `purpose_note`,
`purpose_category_id`, `status` (`open`, `closed`, `void`).
`CHECK (holder_user_id <> funder_user_id)`.

Every lot, including child, return-excess and cash lots, is produced by the replay and upserted by
`lot_key`, so nothing goes stale. People never write lots directly.

### 4.8 `feed_allocations`

`id`, `team_id`, `consumer_event_id`, `lot_key` (null = holder's own money), `spender_user_id`,
`amount`, `reason_code` (`no_open_lot`, `note_match`, `received_first`, `reimbursement`,
`return_offset`, `manual`, `pending_pair_hold`), `reason_text`, `state` (`computed`, `pinned`, `broken`), `expense_id` (plain bigint, maintained by the write path,
not an FK action), `created_at`.

### 4.9 `feed_review_items` and `feed_review_comments`

`feed_review_items`: `id`, `team_id`, `kind` (`allocation`, `pair`, `duplicate`, `low_confidence`,
`annotation`, `expense_change`, `broken_pin`, `member_left`), `subject_event_id`, `payload` (jsonb
snapshot of the proposal), `reason_text`, `revision` (bumped when a replay changes the proposal),
`status` (`open`, `resolved`, `superseded`), `funder_user_id` (so the funder can see and comment on
it), `resolved_by`, `resolved_at`, `created_at`. One open item per `(kind, subject_event_id)`.

`feed_review_comments`: `id`, `team_id`, `review_item_id`, `user_id`, `body`, `created_at`.

### 4.10 `feed_team_settings`

Operational settings only; there are no funding rules to configure (section 19). JJ-owned, not
`settings.team_settings` (shared by four products, keyed by team with no `id`, no JJ insert grant,
so its activity trigger would skip changes).

`feed_team_settings`: `id`, `team_id` (unique), `enabled`, `backfill_from` (date),
`min_parser_version`, `raw_text_retention_days` (90), `updated_by`, `updated_at`. Activity trigger
on change.

Fixed in code, not settings: allocation order received first, lots never expire, no category is
excluded from lots, only alpha decides links, settle window 30 minutes with a 24-hour cap (5.7).
Own-first was removed in revision 3: it needs per-account balances the parser does not read, and
its results changed between runs.

### 4.11 `expense_sources`

`id`, `team_id`, `expense_id` (FK, on delete cascade), `source` (`manual`, `statement_import`,
`feed`), `source_ref` (statement line hash or feed event id). Lets each import path see what the
others already created.

### 4.12 Service user for background work

The ledger insert policies require `app.current_role` in `alpha, beta, gamma`
(`packages/@joint-journey/db/src/rls.sql` lines 35-38); activity inserts require
`user_id = app.current_user_id` (lines 74-77); `user_id` columns have FKs to `auth.user`.
So the matcher's background work runs as a real user:
- A `feed-matcher` service user is created through the Better Auth users-admin workflow (never direct
  SQL), added to each team that enables the feed, with role `beta`. The alpha enables the feed for
  a team, which triggers this provisioning.
- Background calls run through `withRLS` with that user's id, the team id and role `beta`, so
  ordinary policies apply. It has no `BYPASSRLS` and is not a superuser.
- Inline matcher runs after an upload use the same service context, so the uploading member's role
  (possibly gamma) never limits matcher writes.

### 4.13 RLS policies

The default helper in `rls.sql` gives team-wide SELECT, which is too wide here, so every feed table
gets its own policies in the migration.

| Table | Read | Write |
|---|---|---|
| `feed_devices` | owner; alpha | owner insert; owner or alpha revoke |
| `feed_rows` | owner; alpha and beta see rows only through `feed_rows_team_view` | API insert for own `user_id`; status and event updates by the service user |
| `feed_annotations` | owner; alpha | owner insert |
| `feed_events`, `feed_pairs`, `feed_lots`, `feed_allocations` | member is holder, funder, spender or counterparty (policy uses `security definer` helper functions so the joins stay indexed); alpha and beta | service user; decision routes |
| `feed_review_items`, `feed_review_comments` | alpha and beta; the funder for items naming them | service user creates items; deciders resolve; any role comments |
| `feed_team_settings` | all team members | alpha only |
| `member_identities` | owner; alpha | owner insert; alpha verify |
| `expense_sources` | same as `ledger.expenses` | API only |

Column-level privacy uses a view, since RLS works on rows: `feed_rows_team_view` returns
`merchant`, `note`, `counterparty_*` as null for private rows and never exposes `raw_text`. Direct
`SELECT` on `feed_rows.raw_text` is revoked from the application role; the owner reads it through
`feed_row_raw_text(id)`, a function that checks `user_id = app.current_user_id`. Funders see a
holder's spend only as amount, date and category in the lot view, not merchant or note.

## 5. Processing pipeline (server)

### 5.1 Locking

Every write for a team (ingest, annotations, matcher, decisions, settings changes, nightly job) runs
under one lock: `pg_advisory_xact_lock(hashtext('feed:' || team_id))`. One lock per team means no
lock ordering and no deadlocks, and a household's write volume is small enough that serializing it
costs nothing noticeable.

### 5.2 Ingest

Insert-or-return-existing on `(team_id, device_id, client_message_id)`. Reject versions below
`min_parser_version`. Check that the uploader is still a member of the team in `auth.team_member`
(a removed member's session may still resolve for up to 30 s); reject with 403 `NOT_A_MEMBER`
otherwise. Rows dated before `backfill_from` are stored as `ignored`. After commit, the API calls
the matcher for the team (5.9).

### 5.3 Event grouping

The phone already merged SMS and email copies, so server grouping only joins rows that describe the
same side of the same movement from different devices, plus duplicate alerts from one device.

Rules, in order:
1. Never group rows with different directions. P1's debit and P2's credit of one transfer stay two
   events; pairing (5.6) joins them.
2. Same direction, same normalized reference, same amount: one event (covers a bank alerting a
   joint account on two phones, and one phone receiving a duplicate alert from two sender ids).
3. Same direction, same bank and account hint, same amount, no reference, from different devices,
   within 10 minutes: one event.
4. Same device, same direction, same amount, no reference, within 2 minutes, different messages:
   two events plus a `duplicate` review item ("possible duplicate alert"). The alpha merges or
   keeps both.
5. Anything ambiguous (two candidates): separate events plus a review item.

### 5.4 Matching existing expenses

For each new debit event, look for an existing `ledger.expenses` row from manual entry or a
statement import. This uses a feed adapter that takes the caller's transaction (the existing
`bankMatchRepository.findMatches`,
`packages/@joint-journey/db/src/repositories/unresolved-boundaries.ts:1048`, opens its own
`withRLS` transaction and matches on a 2-day window with names, so it cannot run inside the lock).
The adapter matches amount, a 1-day window, bank and reference when present. A match sets
`matched_expense_id`; attribution still runs, and if a funder paid, a review item proposes changing
that expense's `member_user_id`.
In the other direction, the statement importer (phase 4 change) checks `expense_sources` and feed
events before creating rows, and treats a bank line that matches a paired transfer as a transfer.

### 5.5 Server categorization

Before allocation: an alpha-confirmed merchant rule, then `ledger.categories.keywords` (a free-text
field, tokenized on commas, whitespace and punctuation, lower-cased) matched against merchant and
note tokens, then the phone's `category_hint` matched by category name. Phone category ids are never
sent. Uncategorized events are still allocated. Category only orders lot suggestions (6.3 step 1);
it never decides whose money was used.

### 5.6 Classification and pairing

- `self_transfer`: `transfer_kind = self`, or both sides are verified identities of one member.
- `card_bill`: `transfer_kind = card_bill`.
- `transfer_out` / `transfer_in`: the counterparty is a verified identity of another member, or
  `transfer_kind = p2p` with a pair found.
- `atm`, `wallet_topup`, `income`, `refund`, `reversal`, `spend` from mode, direction and flags.

Pairing:
- A debit and another member's credit with the same reference and amount pair automatically
  (`reference`, accepted).
- Without a reference: same amount, opposite direction, two members, within 10 minutes: proposed
  (`amount_time`).
- One-sided: the counterparty identity is verified but the receiver's side never arrived (no phone,
  or not synced within the settle cap): proposed (`one_sided`), with the credit side null.
- Proposed pairs are decided by an alpha; the two members can comment.

### 5.7 Settle window

The replay attributes an event only when both hold: it is older than 30 minutes, and every active
team device's `synced_through` is later than it. A device that has not synced for 24 hours stops
blocking; events then settle on the window alone. This stops a spend
from being attributed before the transfer that funded it arrives from the other phone, without one
switched-off phone blocking the team forever.

### 5.8 Write-through and review

After a replay:
- Auto-written to `ledger.expenses`: allocations with reason `no_open_lot` only (the holder spent
  their own money and no other member's money was with them). Exception:
  while a `proposed` pair into the holder is undecided, every spend by that holder dated after the
  pair's debit gets `pending_pair_hold` and is not written until the pair is decided.
- Review items: every allocation that uses a lot (a suggestion until an alpha accepts it), proposed
  pairs, duplicates, low confidence, annotation
  conflicts, broken pins, and any change to an already-written expense.
- Keep separate: pins the consumer to the holder's own money; it is never proposed again.
- Phase 2 (before transfers exist): only events with `transfer_kind = none` that are not
  `isPersonToPerson` are auto-written. P2P and transfer rows wait in review as "transfer, not yet
  classified" until phase 3 classifies them.

Write-through creates one expense row per allocation: `type = 'Expense'`, `user_id` = the
feed-matcher service user for automatic writes or the deciding member for decisions,
`member_user_id` = spender, `amount`, `occurred_at`, `transaction_mode`, `bank_name`, `notes`
(merchant or UPI note), `statement_text` (only when raw text was opted in), `category_id`; plus an
`expense_sources` row and `feed_allocations.expense_id`.

### 5.9 Reversals, refunds and JJ-side edits

- Reversal: a row with `is_reversal` links to the original event by `reverses_reference`, else by
  amount, account and a 7-day window (review item if ambiguous). Full reversal: original `reversed`,
  its allocations drop out in the next replay. Partial: original `partly_reversed`,
  `reversed_amount` set, and the replay treats the consumer as `amount - reversed_amount`.
- A reversed transfer-out removes the pair's effect: the replay no longer produces the lot it
  created or any child lots, and re-attributes everything that drew on them.
- Refund: a merchant credit matched to an earlier spend (same merchant, not above the spend, within
  60 days) is a source event at its own date. It returns money to the lots the spend used, in the
  same proportions, as new lot capacity from the refund date (not back-dated).
- Any change to an allocation that already has an expense row becomes an `expense_change` review
  item; the expense changes only when it is accepted.
- JJ edit guard: feed-created expenses cannot have amount or member changed through the normal
  expense routes, using the same sync-guard approach as `syncVehicleBillFromExpense`
  (`unresolved-boundaries.ts:1162`). Deleting a feed-created expense runs an after-delete hook in the
  expense delete path that pins that allocation as `manual` own money of the holder (or removes it
  from the lot, if the alpha chose "ignore"), and clears `expense_id`.

### 5.10 Runtime and the nightly job

The JJ API has no job runner.
- The matcher runs inline after each ingest commit, as the service user, for the uploading team.
- `POST /api/feed/jobs/nightly` is called by a Coolify scheduled task with `X-Feed-Job-Secret`
  (stored in the Coolify env and in OpenBao). It loops over teams with the feed enabled and, for each
  team under its lock: re-runs the matcher (covers a process that died after commit), retries feed
  rows still `new`, purges raw text past `raw_text_retention_days` (`feed_rows.raw_text` and the
  matching `ledger.expenses.statement_text` of feed-created rows), and checks `auth.team_member` for
  members who left (8).

## 6. Funding attribution rules

### 6.1 Sources and consumers

- Sources (add lot capacity for the holder): accepted pairs into the holder (`transfer_in`), refunds
  (5.9), ATM withdrawals (into a cash lot of the same funders).
- Consumers (draw from lots or own money): spends, `transfer_out`, ATM withdrawals, card bills.
- Neither: self transfers, wallet top-ups (the later wallet spend is entered manually and is the
  consumer), income.

### 6.2 Team replay with pins

Attribution for a team is a pure function of its events, accepted pairs and pins. The rules in 6.3
are fixed in code, so there is no rules input.

Order: events are walked by `order_key = (occurred_at, direction credit before debit,
reference, sha256 of client_message_id)`. All parts come from content, not arrival, so any
arrival order produces the same walk. Credits first means a transfer arriving in the same second as
a spend funds it.

Each run, under the team lock:
1. Load the team's settled events from the replay start point (below), accepted pairs and pins.
2. Reserve pins: for each lot, the pinned allocations against it are reserved before the walk. When
   a pin is set, the decision route checks under the lock that the reservation fits the lot at that
   point in the walk; otherwise it returns 409 `PIN_DOES_NOT_FIT`.
3. Walk all holders together in `order_key` order, keeping each lot's remaining capacity
   (`amount - reserved - drawn so far`) in memory. For each consumer: apply its pins, then the rules
   in 6.3 to the unpinned amount. Outgoing transfers create child lots for the receiver (6.4).
4. A pin that no longer fits (a late earlier event drained the lot, the lot became void, or the
   consumer shrank below its pinned total) is marked `broken`, its amount is attributed by the rules
   instead, and a `broken_pin` review item is raised.
5. Compute the full new set of lots and allocations in memory, diff against the stored set, then
   upsert lots by `lot_key` and allocations by `(consumer_event_id, lot_key)`. Rows without an
   expense change freely. Rows with an expense produce `expense_change` review items instead of
   changing. Stored rows not in the new set are deleted only if they have no expense.

Replay start point: the earliest event affected by the change (a new or late event, a reversal, a
pin), moved back to the start of the oldest lot still open at that time. The walk starts from a
balance checkpoint: the stored lots' `remaining` as of the checkpoint date, which is saved by every
completed replay. Because lots never expire, an old unspent lot keeps the start point early; an
alpha closes its remaining balance from the open lots list (7). Because the team's
own history is small (household volume) the worst case, a full replay, is still a few thousand rows.

### 6.3 Rules for one consumer (received first)

These steps produce a suggestion. Any part drawn from a lot is a review item until an alpha accepts
it (5.8); only the own-money part with no open lot is written automatically.

1. Note match: an open lot whose purpose category equals the consumer's category, or whose purpose
   note shares a keyword token (5.5) with the consumer's merchant or note, is used first; oldest
   first among several. With no note on any lot, this step does nothing.
2. Received first: the rest drains open lots oldest first (FIFO across funders).
3. Own money: whatever is left.

No expiry and no excluded categories. The members set category and sub-category themselves, and the
alpha sees each suggestion with the lot's age ("from P1, 42 days ago") and its category, then
accepts it, changes the split, or picks "Keep separate", which pins it to the holder's own money so
it is never suggested again.

### 6.4 Passing money on (multi-hop)

When P2 sends money to P3 and the replay draws that transfer from P1's lot, P3 gets a child lot
with `funder_user_id = P1`, `parent_lot_id` = P1's lot, `root_opened_at` from the root, and
`lot_key = transfer_in_event:P1`. The part drawn from P2's own money opens a second lot for P3
funded by P2 (`lot_key = transfer_in_event:P2`). One transfer can therefore create several lots,
which is why lots are keyed by event and funder.

### 6.5 Returns and reimbursements

- Return: when P2 sends money to P1 while P2 holds lots funded by P1, the transfer first consumes
  those lots (`return_offset`). Only the excess creates a lot for P1 funded by P2. Holder and funder
  are never the same.
- Reimbursement: P1 sending money to P2 after P2 spent for P1 is never linked backwards
  automatically; it creates a normal lot. An alpha may pin a backward link (`reimbursement`), which
  consumes that lot, so the same money is never used twice.
- Tolerance: only return offsets and reimbursement pins accept a difference of up to 1 percent or 10
  rupees, whichever is larger; the difference stays as the holder's own money. All other
  allocation is exact.

### 6.6 Worked example

| Step | Event (P2 is holder) | P1 lot remaining | Allocations |
|---|---|---|---|
| 1 | 3 Nov: P1 sends 1000 to P2, note "groceries" | 1000 | none (internal transfer) |
| 2 | 5 Nov: P2 spends 400 at a grocery | 600 | suggested 400 P1 (`note_match`); alpha accepts |
| 3 | 6 Nov: P2 spends 900 at a pharmacy | 0 | suggested 600 P1 (`received_first`), 300 P2 (own); alpha accepts |
| 4 | 7 Nov: P2 spends 200 | 0 | 200 P2 (`no_open_lot`, auto-written) |
| 5 | 8 Nov: P1's phone syncs late | unchanged | the replay gives the same result: dates decide, not arrival |

## 7. Alpha control

- No funding-rules screen. The only alpha setting is the feed itself (`GET/PUT /api/feed/settings`:
  enable, backfill date, minimum parser version, raw-text retention), with `PUT` checked the same way
  `PATCH /api/preferences` checks the team business category
  (`apps/api/src/app/api/preferences/route.ts` line 64), enforced again by RLS, and logged by the
  activity trigger for the alpha-only activity view (`/api/activity`).
- Review queue: each item shows the event, its category and sub-category as the member set them,
  the suggested split, the lot's funder and age, and "Why this split" (`reason_text`). Actions:
  Link (accept), Change split, Keep separate. "Accept all" accepts every visible suggestion in one
  call, so routine items cost one tap. Decisions carry the item's `revision` and are a
  compare-and-set: a stale revision returns 409 and the UI reloads.
- Open lots list: every lot still holding money, oldest first, with holder, funder and age. Since
  lots never expire, an alpha can close a lot's remaining balance ("the rest is the holder's own");
  this is stored as a pin, so the replay honours it and the lot stops receiving suggestions.
- Who decides: alpha only. Beta and gamma suggest by commenting; the funder named on an item can see
  it and comment.
- The queue is separate from `jointjourney.edit_requests` (gamma-create only, expense and income
  edits, no delete) and reuses the statement-import pending queue layout
  (`/api/statement-imports/pending`).

## 8. Remaining edge cases

| Case | Handling |
|---|---|
| Joint account or add-on card alerting two phones | One event (5.3 rule 2 or 3); holder and spender from `default_spender_user_id`, overridable in review. |
| Card or UPI used by someone other than the phone owner | `default_spender_user_id`; per-event override. |
| Card bill paid by another member | P1 paying P2's card bill: a transfer-in for P2 (lot funded by P1); the card-bill payment then consumes it. Card spends are attributed when they occur. |
| Cash | An ATM withdrawal consumes lots and creates a cash lot with the same funders; manual cash expenses can be pinned to it. |
| Money from outside the team | Income or the holder's own money. |
| Money to someone outside the team | A spend, unless marked a loan; loans go to JJ debt (`POST /api/debt/accounts`, `POST /api/debt/transactions`). |
| Autopay, mandates, EMI, subscriptions | Normal spends by the holder (UPI, netbanking or card in the parser). |
| Member leaves the team | Detected at ingest and by the nightly job through `auth.team_member` (a removed member gets 401 or `NOT_A_MEMBER`, not a 403 on other routes). Their devices are revoked; lots they hold are `closed` as "unspent, with <member>" and raise a `member_left` review item; lots they funded stay valid for the holders; their written expenses stay. |
| Several teams | Account-to-team mapping and per-team sync (3.2). |
| Foreign currency | Original and converted amounts stored; lots and allocations use the INR amount; rows without one go to review. |
| Time | `occurred_at` is the SMS receive time (`occurred_at_source = received`), email date for email rows; timestamptz. |
| Low parser confidence | Review item; never auto-written. |

## 9. Privacy, security and threat model

| Threat | Mitigation |
|---|---|
| Lost or stolen phone | Revoke the device (feed routes immediately; session revocation once the auth-service endpoint exists, 3.1); Pckt's app lock. |
| A member reading another's bank detail | Per-table RLS and the team view (4.13); raw text owner-only; private rows. |
| Spoofed identities | Auto-verification only from the owner's own phone; otherwise alpha. |
| Replayed uploads | `client_message_id` uniqueness and the device check. |
| Interception | HTTPS only. |
| Raw text retention | Opt-in; owner purge any time (`DELETE /api/feed/rows/raw-text`, which also clears the `statement_text` of feed-created expenses); automatic purge after `raw_text_retention_days` (90) by the nightly job. Both from phase 2. |
| Third-party LLM | Off by default; disclosed when enabled. |
| Job endpoint abuse | Secret header; the job only performs fixed maintenance for teams with the feed enabled. |

## 10. Lifecycle summary

| Object | States | Moves when |
|---|---|---|
| Feed row | `new` -> `grouped`; `ignored`; `rejected` (never stored, returned in the result) | grouping; backfill cut-off; version cut-off |
| Event | `open` -> `attributed`; `ignored`; `partly_reversed`; `reversed` | replay; alpha ignore; reversal |
| Pair | `proposed` -> `accepted` / `rejected` | reference rule auto-accepts; others by decision |
| Lot | `open` -> `closed` / `void` | replay (empty, kept separate by an alpha, or member left); reversal of its source |
| Allocation | `computed` <-> `pinned` -> `broken` | replay; decision; pin no longer fits |
| Review item | `open` -> `resolved` / `superseded` | decision; a later replay replaces it |
| Expense (feed) | created -> changed or deleted only via review | write-through; review |

## 11. API contracts (zod schemas live with the routes)

- `POST /api/feed/rows`: `{ rows: FeedRowInput[] }` (max 100) -> `{ results: { client_message_id,
  id?, status, reason? }[] }`.
- `POST /api/feed/rows/{client_message_id}/annotations`: `{ client_seq, kind, value }` -> 201, or 200
  when that `(device_id, client_seq)` exists.
- `DELETE /api/feed/rows/raw-text`: `{ ids?: number[] }` (all own rows when omitted) -> 204.
- `GET /api/feed/review?cursor=&kind=` -> `{ items: ReviewItem[], next_cursor }`.
- `POST /api/feed/review/{id}/decision`: `{ action: link | split | separate, allocations?,
  revision }` -> 200; 409 stale revision or `PIN_DOES_NOT_FIT`; 403 when the caller is not alpha.
- `POST /api/feed/review/accept`: `{ items: { id, revision }[] }` (alpha) -> per-item results;
  stale or non-fitting items are skipped and reported, the rest are accepted.
- `POST /api/feed/review/{id}/comments`: `{ body }` -> 201.
- `GET/PUT /api/feed/settings`: `feed_team_settings` fields.
- `POST /api/feed/devices`: `{ device_id, label, app_version }`; `DELETE /api/feed/devices/{id}`.
- `POST /api/feed/jobs/nightly`: header `X-Feed-Job-Secret`; -> `{ teams, replays, purged }`.

## 12. Performance

- Indexes: `feed_rows (team_id, device_id, client_message_id)` unique; `feed_rows (event_id)`;
  `feed_events (team_id, order_key)`; `feed_events (team_id, reference)`;
  `feed_lots (team_id, lot_key)` unique; `feed_lots (team_id, holder_user_id, root_opened_at) where
  status = 'open'`; `feed_allocations (consumer_event_id)`, `(team_id, lot_key)`;
  `feed_review_items (team_id, status, created_at desc)`.
- Replays start from the earliest affected event and a stored checkpoint (6.2), not from the
  beginning of history.
- Ingest is batched (100 rows, one transaction per batch under the team lock).
- The workspace 31-item performance checklist and the 5 performance prompts are applied in each
  phase's done-gate.

## 13. Alternatives considered

- Holder is always the spender, monthly settle-up through JJ debt. Simpler, but it answers "who owes
  whom", not "whose money was spent". Kept as the automatic default for spends without an open lot.
- Lots only for transfers with a note. Simpler, but most family transfers carry no note.
- Stored balances updated incrementally. Rejected: depends on arrival order and drifts; the replay
  is deterministic.
- Per-holder locks. Rejected: transfers span holders, so replays cascade and can deadlock; one team
  lock is simpler and cheap at household volume.

## 14. Phases

### 14.1 Migrations (in order)

| Id | Phase | Contents |
|---|---|---|
| 1a | 1 | `feed_devices`, `feed_team_settings`; RLS; activity trigger on settings |
| 2a | 2 | `feed_rows` (without `event_id`), `feed_annotations`, `expense_sources`; `feed_rows_team_view`; column revoke; `feed_row_raw_text()` |
| 2b | 2 | `feed_events`, `feed_review_items`, `feed_review_comments`; add `feed_rows.event_id` FK |
| 3a | 3 | `member_identities`, `feed_pairs` with partial unique indexes |
| 4a | 4 | `feed_lots`, `feed_allocations`, helper functions for the RLS read predicate |

Each migration is a reviewed SQL file, dry-run on a `varsys_dryrun` clone before production
(workspace rule after the 2026-10-25 lock incident).

### 14.2 Phase contents and tests

| Phase | Ships | Tests |
|---|---|---|
| 1 | Rebrand (name, package id, icons), GPL notices and About screen, HTTPS only, Better Auth sign-in, device registration, feed-matcher service user provisioning, auth-service session-revoke check | sign-in on a device; revoked device gets 403; RLS on settings: gamma and beta cannot PUT |
| 2 | SMS feed: outbox, receiver plus WorkManager, `client_message_id`, privacy toggle, raw-text opt-in, purge route and retention, `transfer_kind`, event grouping, matching existing expenses, auto-write of non-transfer spends with the holder as spender, nightly job | retransmit is idempotent; duplicate alerts on one device go to review; joint account on two phones gives one event; RLS reads with beta and gamma accounts (no other member's raw text or private detail); cross-team read denied; feed-matcher writes succeed under RLS |
| 3 | UPI note and VPA extraction, identities, pairing, transfers excluded from spend, phase 2 held transfers classified | both-phone reference pairing; one-sided pair; concurrent uploads from two phones under the team lock |
| 4 | Lots, replay with pins, review queue UI with "Accept all", reversals and refunds, statement-import check, JJ edit guard and delete hook | shuffled arrival order gives identical lots and allocations; pin that stops fitting becomes broken; reversal of a spent lot re-attributes child lots; a lot-linked spend is never written before an alpha accepts it; beta and gamma decisions get 403 but comments succeed; stale decision 409; "Accept all" skips stale items; edit guard blocks amount change |
| 5 | Email (Gmail, IMAP), cash lots, card-bill linking, member leaving | per case |

Every phase also updates `docs/diagrams/joint-journey` (flowchart, sync sequence, data model,
state machines) and passes the workspace done-gate.

## 15. Risks

- Parser coverage across banks decides everything downstream; low-confidence rows go to review.
- Alpha review load: every lot-linked spend needs an alpha decision. Limited by auto-writing
  no-lot spends and by "Accept all"; measured in phase 4.
- With no excluded categories, a wrong suggestion (a holder's personal spend drawn from a funder's
  lot) is caught only by alpha review; "Keep separate" fixes it permanently.
- Sideloaded app versions drift: minimum parser version cut-off.
- The auth-service session-revoke endpoint may need building (phase 1).
- GPL obligations: source must stay published.

## 16. Open decisions

- Raw-text retention period (default 90 days).
- Whether reference-matched pairs auto-accept (planned: yes) or need an alpha tap.

## 17. Review 1 coverage (29 findings)

1 purpose and alternatives: 1, 13. 2 ordering: 4.7, 5.7, 6.2. 3 concurrency: 5.1, 6.2. 4 auto-write:
5.8. 5 idempotency vs duplicates: 4.2, 5.3. 6 append-only vs edits: 4.2, 4.3. 7 RLS: 4.12, 4.13.
8 rules table: 4.10. 9 team switching: 3.2. 10 Pckt gaps: 2.1, 2.2. 11 reversals and JJ edits: 5.9.
12 cross-source: 4.11, 5.4. 13 multi-hop and returns: 6.4, 6.5, 5.6. 14 device security: 3.1.
15 category: 5.5. 16 card bills: 2.2, 8. 17 double use: 6.5. 18 own-first: 4.10. 19 privacy: 3.3, 9.
20 runtime: 5.10. 21 JJ reuse: 7, 8. 22 buildability: 4, 10, 11, 14. 23 phasing: 14.2. 24 updates:
3.5. 25 facts: 2.1, 2.2, 3.3. 26 model gaps: 4.7, 4.8, 4.9. 27 member leaving: 8. 28 structure: 0,
13, 15, 16. 29 style: 0.

## 18. Review 2 coverage (17 partial plus 23 new)

| Finding | Fix |
|---|---|
| B1 pin feasibility | 6.2 steps 2 and 4: reservation, 409 `PIN_DOES_NOT_FIT`, `broken` state |
| B2 grouping both ways | 5.3 rules 1-5 |
| B3 phone-side merge | 2.1, 3.3 `message_ids`, 5.3 scope; phase 2 test changed |
| B4 stale derived lots | 4.7 lots are replay output keyed by `lot_key`; 6.2 step 5 diff and upsert |
| B5 cascade and deadlock | 5.1 one team lock; 6.2 team-wide walk |
| B6 system actor | 4.12 real service user, role beta, users-admin provisioning |
| B7 settle window | 5.7 both conditions, 24 h cap |
| B8 `findMatches` | 5.4 feed adapter in the caller's transaction |
| B9 RLS gaps | 4.13 view, column revoke, owner function, helper functions, beta named, explicit migrations |
| B10 phase 2 transfers | 5.8 last bullet |
| B11 review tables | 4.9 |
| B12 annotation addressing | 3.4, 11 server `id` returned, route keyed by `client_message_id` |
| B13 member removal | 5.2 membership check, 8, 5.10 |
| B14 existing code | 2.1, 2.2 rewritten as extend |
| B15 retention | 3.3, 9, 14.2 phase 2, 11 route |
| B16 nightly job | 5.10 |
| B17 migrations and tests | 14.1, 14.2 |
| B18 determinism and cost | 6.2 content `order_key`, start point and checkpoint |
| B19 auto-write vs pending pair | 5.8 `pending_pair_hold` |
| B20 partial reversal, refund date | 4.4 `partly_reversed`, 5.9 |
| B21 closed status | 4.7 |
| B22 joint-account holder | 4.4 holder rule |
| B23 loose ends | 4.2 mutable columns, 10 `rejected`, 4 money domain, 5.5 tokenizer, 5.9 `syncVehicleBillFromExpense` |
| Partial 9 (switch loop) | 3.2 attempt limit and fixed order |
| Partial 10/25 (facts) | 2.2 reversals parsed as credits; SMS time is receive time |
| Partial 11 (delete hook) | 5.9 after-delete hook, `expense_id` plain column |
| Partial 14 (session revoke) | 3.1 stated as an unverified dependency, checked in phase 1 |
| Partial 19 (statement_text) | 5.10, 9 purge covers feed-created expenses |
| Partial 20 (inline crash) | 5.10 nightly re-run and retry sweep |
| Partial 29 (field name) | `min_parser_version` used throughout |

## 19. Revision 4: no configurable funding rules (2026-11-12)

Decision: members set category and sub-category themselves, and alpha users review every funding
link, so the team rules screen added nothing a reviewer does not already do.

| Removed | Replaced by |
|---|---|
| Allocation order setting | Received first, fixed in code (6.3) |
| Lot expiry (`lot_expiry_days`) | Lots never expire; review shows the lot's age; alpha can close an old lot's balance (7) |
| Personal categories (`feed_personal_categories`) | Alpha rejects a wrong suggestion with "Keep separate" |
| `link_approval` (`funder_or_alpha`) | Alpha only decides; beta, gamma and the funder comment |
| `auto_accept_single_note_match` | Every lot-linked spend waits for an alpha; "Accept all" keeps it to one tap |
| `settle_window_minutes`, `settle_cap_hours` | Fixed 30 minutes and 24 hours (5.7) |
| `rules_version` | Per review item `revision` for compare-and-set |
| `feed_team_rules`, `/api/feed/rules` | `feed_team_settings`, `/api/feed/settings` (enable, backfill date, minimum parser version, raw-text retention) |

Unchanged: the replay, lots, pairs, pins, the no-lot auto-write and every review-2 fix in section 18.

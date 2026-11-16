# Goldfish Review Report (review 2 of 2, final)

**Target:** `D:\my projects\VarSysProjects\VarSys-Expense-Feeder\docs\plan\feed-architecture-plan.md` (lines 1-602, revision 2)

## Reviewer Status

| Reviewer | Status |
| --- | --- |
| `codebase-details` | completed |
| `design` | completed |
| `implementation-readiness` | completed |

Result: 12 FIXED, 17 PARTIAL, 0 NOT FIXED. Section 16 says "all 29 addressed", which overclaims. Not ready to build phases 3 and 4.

## A. Review-1 findings

| # | Verdict | Reason |
|---|---|---|
| 1 | FIXED | Question stated in section 1; alternatives in 14. |
| 2 | PARTIAL | Remaining is derived, but ties are broken by arrival-order `id`, the settle window is inverted (B7), and derived lots go stale (B4). |
| 3 | PARTIAL | The lock is per holder, but pairing, multi-hop, returns and rule changes span several holders: no lock order, so deadlock or missed replays (B5). |
| 4 | FIXED | 5.7 auto-writes `no_open_lot`. Phase 2 side effect in B10. |
| 5 | FIXED | Message-based `client_message_id`; `user_id` removed from the key. New same-device problem in B2. |
| 6 | PARTIAL | Annotations replace re-sends, but the phone cannot address a row (B12), and a "private" mark needs an update that 4.2 forbids. |
| 7 | PARTIAL | RLS is per table and a funder can decide, but the system actor is infeasible (B6) and column-level privacy is not expressible in RLS (B9). |
| 8 | FIXED | Own `feed_team_rules`; the `team_settings` facts check out (no `id`, PK `team_id`). |
| 9 | PARTIAL | TEAM_MISMATCH exists, but "wait out 30 s" has no retry limit, and a phone with accounts in several teams keeps switching orgs. |
| 10 | PARTIAL | Two facts are wrong: reversals are parsed as plain credits, not discarded; SMS never reads a body time. Existing reuse is missed (B14). |
| 11 | PARTIAL | A partial reversal sets the whole event to `reversed`. The delete pin needs `afterDelete`, since a FK `set null` pins nothing. |
| 12 | PARTIAL | The phone dedup merges SMS and email before upload, so server cross-source grouping never sees both copies (B3). `findMatches` does not fit (B8). |
| 13 | PARTIAL | Rules are stated, but child, excess and cash lots are never recomputed, and `source_pair_id unique` blocks the 6.4 split (B4). |
| 14 | PARTIAL | Cleartext and the 401 retry are fixed. Revoking a Better Auth session from JJ is assumed, not verified. |
| 15 | FIXED | Server categorization (5.4) comes before allocation. |
| 16 | FIXED | `transfer_kind` separates `self` and `card_bill`. |
| 17 | PARTIAL | Reimbursement pins consume lots, but nothing checks pin feasibility, so lots can be overdrawn (B1). |
| 18 | FIXED | Own-first is removed consistently. |
| 19 | PARTIAL | Retention contradicts itself (B15). A purge leaves `expenses.statement_text` in place. |
| 20 | PARTIAL | The matcher runs inline after commit with no retry, so rows stay `new` if the process dies. The job's auth and purpose are undefined (B16). |
| 21 | FIXED | Verified: debt routes accept POST, `/api/activity` is alpha-only, and `edit_requests` is gamma-create, expense and income only. |
| 22 | PARTIAL | No review-item entity, no input or output schemas, no migration order, thin tests (B11, B17). |
| 23 | PARTIAL | Phase 2 writes transfers as spends (B10). |
| 24 | FIXED | Version cut-off plus a Store update check. |
| 25 | PARTIAL | `occurred_at_source = body` is impossible for SMS; the reversal claim is wrong. |
| 26 | PARTIAL | No review-item or comment tables; lot status has no `closed`; feed-row states are inconsistent. |
| 27 | PARTIAL | The 403 trigger never fires: a removed member gets 401 from `auth.ts` (B13). |
| 28 | FIXED | Glossary, alternatives, risks and open decisions added. |
| 29 | FIXED | Glossary added. Nit: `feed_min_parser_version` (3.5) and `min_parser_version` (4.9) name the same field. |

## B. New or missed findings

1. **Critical, 6.2: pins have no feasibility rules.** Nothing covers a late, earlier consumer draining a pinned lot, pins totalling more than the lot amount, pins on a `void` lot, or a consumer amount reduced below its pinned total by a partial reversal or refund. **Fix:**
   - Pins reserve capacity before the walk: computed draws see `amount - sum(pins)`.
   - Validate the pin total against lot capacity at pin time, under the lock.
   - A pin that becomes infeasible is marked `broken`, raises a review item and falls back to the rules.
2. **Critical, 5.2: grouping mishandles both kinds of duplicate.**
   - "Same reference and amount = same event" merges P1's debit and P2's credit of an internal transfer, because both carry one UTR. 5.5 then has no two events to pair.
   - The same-device hard rule double-counts real duplicate SMS: bank retries, two sender IDs, a debit alert plus a UPI-app alert.

   **Fix:**
   - Never group rows with opposite directions; key grouping on direction plus (bank, account_hint).
   - Same-device rows with the same reference are one event.
   - Same-device rows with no reference, the same amount and within 2 minutes become a "possible duplicate" review item.
3. **Critical, 2.1, 3 and 5.2: dedup location contradicts itself.** `ingestion_service.dart:197-210` merges SMS and email on the phone (score >= 0.75) and marks the second message `merged`. The server only ever sees merged transactions, yet a feed row is defined as one message. The phase 2 test "SMS and email copy grouped" also contradicts phase 2 being SMS-only. **Fix:** choose one. Either send every raw message and bypass the phone merge, or drop server cross-source grouping. Then fix the phase 2 test.
4. **Critical, 4.7, 6.2 and 6.4: derived lots go stale, and replay orphans expenses.**
   - Child lots, return-excess lots and cash lots depend on the allocations that replay rebuilds, but they are stored rows that never get recomputed.
   - `source_pair_id unique` forbids one transfer yielding a P1-funded lot and a P2-funded lot, and cash lots have no pair at all.
   - Step 1 deletes computed allocations that carry `expense_id`, which orphans written expenses. Step 4 then diffs against rows it has already deleted.

   **Fix:**
   - Derived lots become `computed`, keyed by `(consumer_event_id, funder_user_id)`. Drop the unique constraint.
   - Replay computes the new set in memory, diffs it against the stored rows, then upserts. Allocations with an `expense_id` change only through review.
5. **Critical, 5 and 6.2: cross-holder cascade and deadlock.** A P2 replay changes P3's child lots, so P3 must replay too. Cycles (P3 to P2) can loop, and per-holder locks taken in data order can deadlock. **Fix:** one team-level advisory lock and one team-wide walk in global `(occurred_at, tiebreak)` order. Households are small enough for this.
6. **Critical, 4.11 and 5.7: the system actor as written cannot write.** Ledger inserts require role alpha, beta or gamma; updates require alpha or beta (`rls.sql:35-38`). `user_activity` inserts need `user_id = app.current_user_id` (`rls.sql:74-77`), and `expenses.user_id` and `user_activity.user_id` FK to `auth.user` (`schema.ts:143, 708`). A fixed service id with a custom role either fails RLS or fails the FK inside the activity trigger, which rolls back the ingest. **Fix:** create a real `auth.user` row for `feed_matcher`, run it under role `beta` (or add feed-specific policies keyed on that user id), and say who provisions it per team.
7. **Major, 5.6: the settle window is backwards.** "Whichever comes first" releases attribution after 30 minutes even while P1's phone is offline, which is the case the window exists for. **Fix:** require both conditions, with a hard cap (e.g. 24 h). Phones stale past the cap are excluded and flagged.
8. **Major, 5.3: `findMatches` does not fit the matcher.** It opens its own `withRLS` transaction (`unresolved-boundaries.ts:1062`), so it cannot run inside the advisory-lock transaction. It also uses a +/-2 day IST window, statement row hashes and name matching. **Fix:** write a transaction-taking feed adapter.
9. **Major, 4.11: RLS gaps.**
   - The private rule "merchant and note null" is column-level, which RLS cannot express.
   - "Alpha all" on `feed_rows` exposes `raw_text`.
   - The holder/funder/spender predicate needs joins and shows funders the holder's merchant detail.
   - Beta is never mentioned.
   - "Decision routes" is not a predicate.
   - New `ledger.feed_*` tables get no policies or activity triggers automatically: `rls.sql` lists tables by name, and the triggers covered other schemas.

   **Fix:**
   - Serve rows through owner-aware views and `REVOKE SELECT (raw_text, merchant, note)` on the base table.
   - Write the actual policy SQL.
   - Add a migration that attaches policies and triggers.
10. **Major, 13: phase 2 counts transfers as spending.** Phase 2 auto-writes every spend, but transfer classification arrives in phase 3. **Fix:** in phase 2, auto-write only `transfer_kind = none` rows with no VPA match, and send the rest to review.
11. **Major, 5.7, 7 and 11: review items have no storage.** The decision route needs `{id}`, and suggestion comments have no table. **Fix:** add `feed_review_items` (kind, subject_table, subject_id, status, decided_by and decided_at, plus a superseded-on-replay rule) and a comments table, both with RLS.
12. **Major, 3.4 and 11: annotations cannot be addressed.** The route takes the server row id, but ingest results return only `client_message_id`. **Fix:** return `id` in each result, or key the route by `client_message_id`.
13. **Major, 8: member-removal detection.** A removed member's request gets 401 (`auth.ts` returns null), which is indistinguishable from an outage. **Fix:** check `auth.team_member` at ingest time and in the nightly job.
14. **Major, 2.2 and 3.4: existing code is missed.** `SmsAlertReceiver` with `RECEIVE_SMS` already exists (`AndroidManifest.xml:62-70`), WorkManager is present (`:76-81`), `_detectSelfTransfer` exists, and the SMS inbox id (`sms_source.dart:45`) already survives a re-parse. **Fix:** rewrite 2.2 as "extend", and correct the reversal and body-time rows.
15. **Major, 9 and 13: retention contradicts itself.** "Opt-in, purge any time" sits beside a 90-day auto-purge. The purge job ships in phase 5, but raw text is collected from phase 2. `DELETE /api/feed/rows/raw-text` is missing from 3 and 11. **Fix:** move the purge to phase 2, also clear `expenses.statement_text`, and list the route.
16. **Major, 5.9 and 9: the nightly job is underspecified.** 5.9 says it refreshes notices only; 9 says it purges. Its team enumeration, actor and secret handling are undefined. **Fix:** specify all three, and add a retry sweep for rows left `new`.
17. **Major, 13: migrations and tests are thin.** There is no per-phase migration list or FK order (`feed_rows.event_id` refers to `feed_events`, created later). Tests cover only gamma. **Fix:** add a migration list, and tests for beta, a funder deciding under `funder_or_alpha`, `feed_matcher`, cross-team isolation and the feed-expense edit guard.
18. **Major, 6.2 and 12: the determinism and cost claims are wrong.**
    - Event `id` is assigned in arrival order, so tie-breaks depend on upload order.
    - Reversals, 60-day refunds and pins reach behind the expiry window.

    **Fix:**
    - Define the event `occurred_at` as the body time, else the earliest row time.
    - Tie-break on a content key, sources before consumers.
    - Replay from the earliest affected event, starting from a balance checkpoint.
19. **Major, 5.7: auto-write races pending pairs.** Spends after an unaccepted `amount_time` or `one_sided` pair are auto-written as `no_open_lot`, then flip to review. **Fix:** hold auto-write for a holder while a proposed pair into them is pending.
20. **Minor, 5.8: partial reversals and refunds.** `reversed` drops every allocation, even on a partial reversal. A proportional refund credits the lot retroactively. **Fix:** use `reversed` only for a full reversal, and credit a refund at its own date.
21. **Minor, 8 and 4.7: "closed" is not a lot status.** **Fix:** add `closed`: not auto-used and not re-attributed.
22. **Minor, 4.4: the holder of a joint-account event is undefined.** **Fix:** define it as `default_spender_user_id`, else the first device.
23. **Minor: contradictions and loose ends.**
    - The insert-only list (4.2) omits `event_id` and the private update.
    - The feed-row lifecycle (10) omits `rejected` and has `ignored` reached directly from ingest.
    - The money domain is `jointjourney.money_amnt` with `CHECK >= 0`.
    - `categories.keywords` is free text, so "whole words" needs a tokenizer.
    - The guard to copy is `syncVehicleBillFromExpense` (`unresolved-boundaries.ts:1162`), not `vehicleBillError`.

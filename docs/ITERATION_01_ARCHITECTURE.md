# Global Enterprise Supermarket & Retail ERP
## Iteration 1 — Architecture and implementation baseline

### 1. Product scope
An Arabic-first, RTL, dark enterprise retail ERP for a single operator with branch-aware data structures. Iteration 1 covers product catalogue, barcode and scale-code parsing, POS invoices, stock movements, party balances (له وعليه), cash/wallet/credit payments, double-entry journal posting, dashboard summaries, and optional offline-first synchronization.

**Out of scope:** e-commerce, online storefronts, customer shopping carts, and online order fulfilment.

### 2. Engineering principles
- Offline-first: local SQLite is the operational source of truth on the device.
- Atomicity: posting a sale and all its financial/inventory effects must be one SQLite transaction.
- Traceability: every stock and financial change has a source document and audit trail.
- Idempotency: every queued cloud operation has a stable operation ID; retries must not duplicate effects.
- Least privilege: Firebase rules must not be opened to public read/write.
- Quota awareness: synchronization is batched and budgeted; local operations must continue when cloud sync is unavailable.
- Separation of concerns: UI, application services, persistence, and sync transport remain independently testable.

### 3. Proposed application layers
1. **Presentation:** Arabic RTL screens, reusable widgets, theme, navigation and localization.
2. **State/application:** `SupermarketErpProvider`, `PosAndCatalogProvider`, validation and use-case orchestration.
3. **Domain:** product/unit conversion, barcode parsing, sale posting, stock and party-ledger rules.
4. **Data:** `DatabaseHelper`, `SchemaBuilder`, SQLite repositories and transaction boundaries.
5. **Synchronization:** `ISyncTransport`, `FirebaseFreeTierSyncService`, durable sync queue and quota tracker.

### 4. Core modules and planned files
- `lib/main.dart`, `lib/app/app_shell.dart`
- `lib/theme/app_theme.dart`, `lib/l10n/`
- `lib/providers/supermarket_erp_provider.dart`
- `lib/providers/pos_and_catalog_provider.dart`
- `lib/data/database_helper.dart`, `lib/data/schema_builder.dart`
- `lib/services/posting_and_sales_service.dart`
- `lib/services/scale_and_barcode_parser.dart`
- `lib/sync/i_sync_transport.dart`
- `lib/sync/firebase_free_tier_sync_service.dart`
- Screens: dashboard, POS, product catalogue, parties and vouchers.
- Reusable UI: `PartyBalanceChip` and shared Arabic form controls.

### 5. Data model baseline
The first schema migration is expected to include:
- Organization: `branches`, `users`, `number_sequences`
- Synchronization: `sync_queue`, `firebase_quota_tracker`
- Catalogue: `product_categories`, `products`, `product_units_barcodes`
- Parties: `parties`, `lah_alayh_ledger`
- Accounting: `chart_of_accounts`, `journal_entries`, `journal_lines`
- Cash and payment: `cash_accounts`, `vouchers`
- Sales: `sales_invoices`, `sales_invoice_items`, `sales_payments`
- Inventory: stock movement records linked to source documents (to be formalized in the migration).

All monetary values must use integer minor units or a documented fixed-precision representation; floating-point arithmetic must not be used for posted balances. Quantities and unit conversions must use explicit precision and a defined base unit.

### 6. Atomic sale posting
A sale must be committed in a single SQLite transaction. The transaction includes:
1. Validate invoice lines, product status, unit conversion, price and available stock policy.
2. Allocate an invoice number safely using `number_sequences`.
3. Insert invoice header and invoice lines.
4. Insert inventory movements in the base stock unit.
5. Insert balanced journal entry and journal lines.
6. Insert party-ledger entry when the customer balance changes.
7. Insert payment records and validate wallet/reference details where required.
8. Enqueue the synchronization event.
9. Commit only if every step succeeds; otherwise roll back everything.

No network request is allowed inside this local transaction.

### 7. Barcode and unit rules
- Support ordinary EAN-13 validation using the check digit.
- Scale barcode parsing must be configurable by prefix, embedded product-code length, quantity/weight encoding, and decimal convention; do not hard-code one retailer's format as universal.
- Unit conversions must resolve to a product's base unit before stock is changed.
- Invalid, unknown, or ambiguous codes must return actionable validation errors and must not silently create products.

### 8. Accounting invariants
- Every posted journal entry must balance: total debits equal total credits.
- Posted records are immutable; corrections use reversal/adjustment entries.
- Cash, wallet, credit and party balances must reconcile to their underlying voucher, payment and ledger records.
- Credit sales must update the party balance; immediate payments must be allocated explicitly.

### 9. Offline sync design
- `ISyncTransport` abstracts the remote provider; the domain and POS must not depend on Firebase APIs.
- Queue records carry operation ID, entity type, entity ID, payload/version, creation time, retry count and status.
- Send bounded batches; retry with backoff; make remote writes idempotent.
- Track estimated daily writes and stop/defer noncritical sync before the application safety ceiling.
- The requested planning ceiling is 18,000 writes/day against a stated 20,000/day target; verify current Firebase plan limits and billing documentation before production use.
- Do not assume Firebase Spark provides Cloud Functions. Keep any server-side processing optional and document its plan requirements.
- Firestore security rules must be scoped to authenticated users and authorized branches.

### 10. UI baseline
- Arabic language and RTL layout are defaults, not an afterthought.
- Dark enterprise visual system with clear hierarchy, readable contrast and large POS touch targets.
- POS supports multiple open invoices and rapid keyboard/barcode workflow.
- Dashboard figures must be derived from persisted records and clearly define their date/branch filters.
- Forms show validation messages in Arabic and preserve user input after recoverable errors.

### 11. Verification and release gates
Before tagging `v0.1.0-iter1`:
- Run formatter and static analysis.
- Run unit tests for conversion, barcode check digit, accounting balance and sale rollback.
- Run database migration and repository tests.
- Run widget tests for RTL navigation and key POS flows.
- Build the intended target only after dependencies and SDK are available.
- Record exact commands and outcomes in `DEVELOPMENT_LOG.md`. Never report a check as passed unless it was actually executed.

### 12. Documentation deliverables
Create Mermaid documentation for architecture, ERD, use cases and critical sale-posting sequence. Keep diagrams aligned with the implemented schema and update them with migrations.

---
**Status:** architecture baseline only. This document does not claim that the Flutter application, Firebase integration, tests, or build have been implemented or verified.

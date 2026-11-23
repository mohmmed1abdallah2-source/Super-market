# سجل التطوير

## 2026-11-07
- بدء تهيئة مشروع Global Enterprise Supermarket & Retail ERP.
- التحقق من المستودع والفرع المستهدف: `main`.
- لم تُنفذ اختبارات أو عملية بناء في هذه المرحلة.

- إنشاء `docs/ITERATION_01_ARCHITECTURE.md` وتوثيق النطاق والطبقات ومخطط البيانات ومبادئ البيع الذري والمزامنة دون اتصال.
- لم تُشغّل اختبارات Flutter أو عملية بناء APK بعد؛ المستودع ما زال في مرحلة التوثيق والتهيئة.

## استكمال تأسيس Iteration 1
- استكمال وثيقة الهندسة بمخططات Mermaid: المكونات، ERD، حالات الاستخدام، وتسلسل مسح الباركود والبيع والترحيل والمزامنة.
- إنشاء ثيم Enterprise Dark وRTL، ومكونات دفتر «له وعليه» وشارة حصة Firebase.
- إنشاء نماذج الأصناف والوحدات والباركود والأطراف والدفعات والفواتير والجلسات.
- إنشاء SchemaBuilder لجداول النواة والمنتجات متعددة الوحدات والأطراف والقيود والسندات والمبيعات وحركات المخزون، مع الفهارس وView رصيد الطرف.
- إنشاء SeedData لفرع التطوير وحساب admin ودليل الحسابات والصناديق والمحافظ والأطراف وثمانية أصناف تجريبية، منها الحليب متعدد الوحدات والجبن الموزون PLU 1025.
- إنشاء DatabaseHelper لتهيئة SQLite مع إعدادات Android وWindows.
- إنشاء ScaleAndBarcodeParser للتحقق من EAN-13 وفك PLU والوزن، وPostingAndSalesService لترحيل البيع ضمن معاملة SQLite واحدة مع المخزون والقيد والدفعات ودفتر الطرف وطابور المزامنة.
- إنشاء ISyncTransport وFirestoreSyncTransport وFirebaseFreeTierSyncService للدفعات المضغوطة حتى 100 حدث، مع سقف حجم مستند آمن ومراقبة تقديرية للكتابات.
- إنشاء مزودي الحالة، AppShell، لوحة التحكم، شاشة POS متعددة التبويبات، شاشة الأصناف متعددة الوحدات، شاشة الأطراف والسندات، ونقطة تشغيل التطبيق وتسجيل الدخول المحلي.
- إضافة pubspec.yaml وREADME.md وfirestore.rules وanalysis_options.yaml و.gitignore واختبار EAN-13/باركود الميزان.
- إضافة زر تجربة باركود الميزان باستخدام الرمز الصحيح حسابياً `2010250125000`. الرمز الوارد في المتطلبات `2010250125009` لا يجتاز رقم تحقق EAN-13، ولذلك يرفضه المحلل كما ينبغي.
- إضافة التحقق من أن سند القبض يخص عميلاً وسند الصرف يخص مورداً، وأن دفعات المحفظة مرتبطة بحساب محفظة ورقم إشعار.
- لم يتم إنشاء مجلدات منصات Flutter الأصلية بعد؛ يوضح README أمر `flutter create --platforms=android,windows .` لتوليدها محلياً.
- لم يتم تنفيذ `flutter pub get` أو `dart format` أو `flutter analyze` أو `flutter test` أو `flutter build apk`؛ بيئة التنفيذ الحالية لا تحتوي على Flutter/Dart SDK. لا توجد نتائج اختبارات أو بناء معلنة.
- Firebase لم يُربط بمشروع حقيقي ولم تُنشر القواعد؛ يلزم إعداد Firebase Authentication وCustom Claims وFlutterFire قبل تفعيل المزامنة الفعلية.

## مراجعة تكاملات الدورة الأولى
- فصل واجهة `ISyncTransport` في ملف مستقل، وإضافة زر تسجيل الخروج، وأزرار الأصناف السريعة وتغيير وحدة البيع داخل سلة POS.
- إضافة تحقق من نوع الطرف وحساب الدفع، وتوجيه قيد كل دفعة إلى حساب الصندوق أو المحفظة الصحيح.
- توسيع أحداث المزامنة لتشمل بيانات الفاتورة وبنودها ودفعاتها وقيودها ودفتر الطرف، وكذلك تغييرات الأصناف والوحدات والسندات.
- إضافة حد لحجم حمولة Firestore المضغوطة، وتجزئة الدفعة محلياً إذا اقترب المستند من الحد الآمن، واستخدام SHA-256 لمعرف الدفعة وبصمتها.
- تعديل قواعد Firestore للسماح بإعادة محاولة كتابة الدفعة نفسها فقط إذا بقيت البصمة والحمولة وعدد الأحداث متطابقة.
- تعديل View الأرصدة ليعتمد على `lah_alayh_ledger` حصراً في الأرصدة الظاهرة، مع توثيق ضرورة ترحيل الأرصدة الافتتاحية إلى الدفتر.
- إضافة اختبار تحويل كرتون 24 حبة إلى وحدة الأساس، إلى جانب اختبارات EAN-13 وباركود الميزان.
- ما زالت جميع الاختبارات غير منفذة فعلياً لعدم توفر Flutter/Dart SDK في بيئة التنفيذ الحالية. يجب تشغيل أوامر README محلياً أو في CI قبل اعتبار الدورة ناجحة.

- إضافة تعديل بيانات الصنف مع حماية وحدة الأساس من التغيير بعد الإنشاء، وتحديث رقم إصدار المزامنة.
- جعل إنشاء الصنف ووحداته وأحداث المزامنة عملية SQLite واحدة، وإضافة حركات المخزون إلى حمولة مزامنة الفاتورة.
- فرض تفرد PLU النشط داخل الفرع، وتقييد قراءة كتالوج Firestore بالفرع والتحقق من الحجم الأقصى لحمولة الدفعة.
- لم يُنشأ Tag للإصدار؛ شرطه تنفيذ التهيئة والفحوص والبناء بنجاح أولاً.

## 2026-11-10 — قالب التقارير الرسمية PDF
- إنشاء فرع عمل مستقل: `feature/official-pdf-report-template` انطلاقاً من `main`، دون تعديل `main`.
- إضافة `lib/core/pdf/official_report_template.dart` اعتماداً على الملف الذي أرسله المستخدم، مع إضافة استيراد `dart:typed_data` اللازم لتعريف `Uint8List`.
- إضافة حزم `pdf` و`printing` و`file_picker` إلى `pubspec.yaml`.
- إضافة ملف شعار PNG شفاف افتراضي 1×1 بصيغة Base64 في `assets/images/report_logo.png.b64`.
- في التحديث الأول لم تكن ملفات TTF موجودة بعد؛ أُضيفت لاحقاً من ملفات Noto الرسمية (نسخة hinted) باستخدام نقل Git الثنائي عبر Base64، وتم التحقق من تطابق بصمات Git للملفات مع المصدر.
- لم تُشغّل أوامر Flutter أو الاختبارات أو البناء في هذه البيئة؛ لا توجد نتائج نجاح معلنة.


## 2026-11-10 — تجهيز تنزيل خطوط التقرير
- تأكيد أن ملفّي TTF غير موجودين بعد في الفرع؛ لذلك لم أعتبر الخطوط مضافة أو جاهزة.
- إضافة `tool/download_report_fonts.sh` لتنزيل نسختَي Noto Naskh Arabic Regular وBold من مجلد الخطوط الرسمي، مع تنزيل SIL Open Font License والتحقق من ترويسة وحجم كل ملف.
- إضافة `assets/fonts/README.md` لتوثيق المصدر والترخيص وطريقة تجهيز ملفات الخطوط.
- أُضيف الملفان الفعليان `assets/fonts/NotoNaskhArabic-Regular.ttf` و`assets/fonts/NotoNaskhArabic-Bold.ttf` إلى المستودع، مع التحقق من وجودهما على الفرع ومطابقة SHA لكل ملف مع المصدر الرسمي.
- أصبح سكربت التنزيل اختيارياً لإعادة جلب الملفات عند الحاجة؛ لا يلزم تشغيله لتجهيز الأصول الحالية.
- لم تُشغّل اختبارات Flutter أو البناء.


## استكمال التحقق الآلي لقالب PDF
- تعديل قالب التقرير حتى لا يعرض صورة الشعار الافتراضية الشفافة 1×1؛ إذا لم تُمرر صورة شعار حقيقية يظهر موضع الشعار النصي بدلاً منها.
- إضافة اختبارين لقالب التقرير: توليد PDF مع جدول عربي، وتوليد تقرير بطاقات فقط دون أعمدة.
- إضافة GitHub Actions workflow لتوليد ملفات Android في بيئة CI ثم تنفيذ `flutter pub get` و`flutter analyze` و`flutter test` وبناء APK تجريبي.
- لم تُنفذ هذه الأوامر داخل جلسة العمل الحالية؛ يجب انتظار نتيجة GitHub Actions قبل اعتبار الفحوص ناجحة.


## 2026-11-11 — توثيق شامل لحالة المشروع وخطة الإنجاز
- تمت مراجعة شجرة المستودع على الفرع `feature/multi-store-isolation-foundation`، وقراءة سجل التطوير وREADME وCHANGELOG ووثائق Iteration 1 وIteration 2 وعزل المتاجر ونشر PostgreSQL، وجرد ملفات التطبيق والخادم والحزم والاختبارات وCI.
- إضافة `docs/PROJECT_STATUS_AND_ROADMAP.md` كلوحة الحالة الرئيسية للمشروع بالكامل، لا Neon فقط. تشمل النطاق والقرارات المعتمدة وجرد المكونات المنفذة في المصدر والمراحل المتبقية وبوابات منع الإطلاق وقواعد التوثيق.
- توضيح الفرق بين الملفات الموجودة في المستودع وبين الميزات التي اختُبرت أو نُشرت فعليًا؛ لم يتم إعلان نجاح Flutter analyze/test/build أو نشر API أو اكتمال تعدد المتاجر دون أدلة.
- توثيق حالة Neon كـ Owner-reported: المستخدم أفاد بنجاح الاتصال والترحيلين schema-only وظهور 18 جدولًا. لم نتحقق مباشرة من لوحة Neon.
- تأكيد أن تعدد المتاجر لا يزال قرارًا معماريًا وخطة تنفيذ، وأن خادم API الحالي branch-scoped single-database وليس جاهزًا لعزل قاعدة مستقلة لكل متجر.
- لم تُنفذ تغييرات على كود التطبيق في هذه الخطوة؛ التغيير الحالي توثيقي فقط.


## 2026-11-11 — نتيجة فحص بنية Neon
- أفاد المستخدم بنجاح فحص العلاقات والمفاتيح والفهارس بعد تنفيذ ترحيلات schema-only.
- تحديث وثيقة الحالة الشاملة ووثيقة تقدم Neon لتسجيل هذه البنود كمكتملة حسب إفادة المستخدم.
- لم تُرفق مخرجات الاستعلامات التفصيلية؛ لذلك لا ندعي مراجعتها بصورة مستقلة.
- ما زال فحص Views وFunctions وTriggers، وبيانات الجداول، وصلاحيات دور التطبيق، وTLS والنسخ الاحتياطي مطلوبًا.


## 2026-11-11 — جرد الدوال والمشغلات والعروض في Neon
- أكد المستخدم أن استعلامات `information_schema` أعادت 40 دالة (Functions)، و5 مشغلات (Triggers)، وعرضًا واحدًا (View).
- سُجلت الأعداد باعتبارها نتائج أبلغ عنها المستخدم؛ لم تُرسل أسماء العناصر أو تعريفاتها، ولذلك لم تتم مراجعة منطقها أو سلوكها بصورة مستقلة.
- لا يُعد هذا الجرد وحده إثباتًا لصحة الدوال أو المشغلات أو العرض. الخطوة التالية هي مراجعة مخرجات الأسماء والتعريفات قبل أي تغيير في اتصال API أو صلاحيات قاعدة البيانات.


## 2026-11-11 — استلام قائمة أسماء دوال Neon
- أرسل المستخدم قائمة تضم 40 صفًا من `information_schema.routines`.
- تظهر ثلاثة أسماء ذات صلة مباشرة بمنطق دفتر اليومية: `assert_journal_entry_balanced` و`journal_entry_status_balance_constraint` و`journal_lines_balance_constraint`.
- بقية الأسماء تبدو من وظائف إضافة `pgcrypto` (التشفير والتجزئة وتوليد القيم العشوائية وغيرها). تكرار الاسم لا يعني بالضرورة تكرارًا غير صحيح؛ قد يكون overload بتواقيع مختلفة.
- لم تصل تواقيع الدوال أو أجسامها؛ لذلك لم تُراجع طريقة عمل الدوال الثلاث. كما أن صف الدالة الأخير في النص المرسل لا يعرض قيمة `routine_type` بوضوح.
- الخطوة التالية: قراءة تواقيع وتعريفات دوال دفتر اليومية الثلاث، ثم تعريفات المشغلات الخمسة والعرض الواحد، دون إجراء أي تعديل على قاعدة البيانات.


## 2026-11-11 — إعداد ترحيلات عزل الفروع والتهيئة المحاسبية
- مراجعة ملفات Neon schema-only والترحيل الأصلي لـ Iteration 2، مع مخرجات المستخدم لتعريفات الدوال والمشغلات والعرض والقيود والمفاتيح الفريدة والأجنبية.
- إضافة `docs/neon/003_branch_consistent_composite_constraints.sql`: مفاتيح فريدة مركبة `(id, branch_id)`، وعلاقات أجنبية مركبة تمنع ربط السجلات عبر الفروع في المنتجات والوحدات والمخزون ودليل الحسابات والصناديق والقيود والدفتر والسندات والمبيعات والمدفوعات والمستخدم المسؤول.
- أضاف الترحيل `branch_id` إلى `journal_lines` و`sales_invoice_items` و`sales_payments`، مع BEFORE triggers لاشتقاق الفرع من القيد/الفاتورة المالكة، حفاظًا على توافق INSERTs التي لا ترسل هذا العمود.
- إضافة فهارس مساعدة للعلاقات المركبة، وحذف الفهرس `idx_journal_entries_doc` لأنه يكرر فهرس UNIQUE الموجود على الأعمدة نفسها.
- إضافة `docs/neon/004_baseline_accounting_accounts.sql` لإدخال دليل حسابات أساسي وستة حسابات صندوق/محافظ لكل فرع موجود، بصورة idempotent ودون إنشاء بيانات متجر تجريبية أو أرصدة افتتاحية.
- لم يتم تشغيل أي ترحيل على Neon، ولم يتم تعديل بيانات قاعدة البيانات الحية. الملفات أضيفت إلى فرع العمل فقط.
- لم يتم تشغيل PostgreSQL integration tests أو تحليل SQL على قاعدة اختبار مستقلة؛ لذلك لا ندعي أن الترحيلات اجتازت التنفيذ. يلزم backup/restore checkpoint ومراجعة أسماء القيود الحالية قبل تشغيل 003.
- يجب تشغيل 004 بعد إنشاء الفرع الحقيقي؛ إذا شُغّل قبل وجود فرع فسيضيف صفر صفوف ولا يهيئ الفروع التي تُنشأ لاحقًا تلقائيًا.

## 2026-11-11 — Corrected Neon post-migration audit
- أضيف `docs/neon/005_post_migration_deep_audit_read_only.sql` كاستعلام واحد للقراءة فقط، يعرض تقرير JSON شاملًا عن المفاتيح الأجنبية المركبة وأعمدتها الفعلية، والمفاتيح الفريدة المركبة، وأعمدة `branch_id` والمشغلات، والأعداد الفعلية للجداول الأساسية، والحسابات التأسيسية، وتوازن قيود اليومية، وصلاحيات الدور الحالي.
- صُححت مقارنة العلاقات لتستخدم `pg_constraint.conkey/confkey` وأسماء الأعمدة المرتبة بدل مقارنة نص تعريف FK، وصُححت أعمدة مبالغ اليومية إلى `dr_amount` و`cr_amount` وفق المخطط الفعلي.
- المخرجات المرفقة سابقًا تُظهر 18 جدولًا فارغًا وما زالت تعرض أسماء المفاتيح الأجنبية القديمة أحادية العمود ومشغلي دفتر اليومية فقط. لذلك لا تثبت تلك اللقطة تنفيذ migration 003؛ وقد تكون سابقة لتنفيذ المستخدم اللاحق. يلزم تشغيل الاستعلام 005 للحصول على حالة حديثة.
- بما أن لقطة الفحص تعرض صفر فروع، فإن migration 004 لم يكن ليضيف حسابات تأسيسية وقت التقاطها. لا تُعد تشغيل أي ترحيل قبل فحص الحالة الحالية.
- أضيف الاستعلام إلى فرع `feature/multi-store-isolation-foundation`. لم ننفذه على Neon ولم نشغّل اختبارات PostgreSQL؛ لا ندعي نجاحًا غير موثق.


## 2026-11-11 — Prepared rollback-only Neon integration tests

- Added `docs/neon/006_branch_isolation_transactional_tests.sql` on `feature/multi-store-isolation-foundation`.
- The script creates two temporary branches and their minimum dependent records inside one transaction, then rolls the entire transaction back.
- Positive assertions cover a balanced posted journal entry and same-branch invoice item/payment creation.
- Negative assertions expect PostgreSQL foreign-key rejection for cross-branch journal accounts, invoice products, payment cash accounts, and sync idempotency receipts.
- Trigger assertions verify that `journal_lines.branch_id` and `sales_invoice_items.branch_id` are derived from their parent records rather than trusted from caller input.
- Accounting negative assertion expects an unbalanced posted journal entry to be rejected by the deferred balance constraint.
- Safety: run the complete script as one transaction against a disposable database with migrations 001–003 applied; do not use autocommit-per-statement. It ends with `ROLLBACK` and is not intended to be run against a live business database.
- Verification status: **prepared only**. The SQL has not been executed against PostgreSQL/Neon in this session. No database test pass is claimed. API authorization, actual sale atomicity, offline replay and multi-device synchronization remain separate tests.


## 2026-11-11 — نتيجة اختبار عزل الفروع في Neon (006)
- أرسل المستخدم نتيجة التنفيذ النهائية للملف `docs/neon/006_branch_isolation_transactional_tests.sql`.
- جميع التأكيدات العشرة في صف النتيجة كانت `true`: إنشاء فرعين مؤقتين، ترحيل قيد متوازن، اشتقاق فرع القيد وبند الفاتورة من السجل الأب، رفض الحساب/المنتج/حساب الدفع/إيصال idempotency من فرع آخر، قبول الدفع داخل الفرع نفسه، ورفض قيد يومية غير متوازن.
- أفادت النتيجة بأن جميع الصفوف مؤقتة وأن `ROLLBACK` التالي يزيلها.
- سُجلت النتيجة كـ **Owner-reported / output supplied: PASS**. لم يتصل المساعد بحساب Neon ولم ينفذ SQL بنفسه.
- يغطي الاختبار قيود قاعدة البيانات المحددة في الملف فقط؛ لا يثبت صحة مصادقة API أو ذرية دورة البيع عبر Dart API أو مزامنة الأجهزة أو عزل قاعدة بيانات مستقلة لكل متجر.
- أُغلقت مرحلة اختبار 006 وانتقل العمل إلى مراجعة وتوثيق تكامل API ودورة البيع؛ لا حاجة لإعادة هذا الاختبار ما لم يتغير المخطط أو منطق القيود.


## 2026-11-11 — مراجعة تكامل API ودورة البيع
- تمت مراجعة ملفات `server/bin/server.dart` وواجهات مسارات البيع والمزامنة والدفتر ومستودع PostgreSQL وواجهة POS المحلية.
- أُنشئ `docs/API_INTEGRATION_REVIEW.md` لتوثيق الموجود فعليًا والفجوات وترتيب التنفيذ.
- الموجود في المصدر: اتصال PostgreSQL واحد للخادم، مصادقة branch token ثابتة مع `X-Branch-Id`، معاملات PostgreSQL لمسار البيع والدفعات، ومسار POS محلي يسبق المزامنة الشبكية.
- الفجوات الأساسية: لا توجد هوية حساب/عضويات متجر موثقة أو control-plane أو توجيه قاعدة بيانات لكل متجر، ولا يوجد مزود SQLite مستقل لكل متجر. كما يستخدم مسار البيع `double` في الحسابات المالية ويحتاج نموذجًا عشريًا وسياسة تقريب واضحة.
- هذه مراجعة مصدرية فقط؛ لا تدعي نشر API أو نجاح اختبار بيع حي على Neon أو نجاح اختبارات تشغيلية في هذه الخطوة.
- التالي: تثبيت عقد المال والمزامنة واختباراتهما، ثم تنفيذ مصادقة المتجر وتوجيه قواعد البيانات وعزل SQLite.

## 2026-11-11 — مراجعة الدقة المالية وعقد المزامنة
- مراجعة اعتماديات Flutter والخادم، ومستودع PostgreSQL للمبيعات والمزامنة، وخدمة POS المحلية، ومخطط Iteration 2.
- إنشاء `docs/FINANCIAL_PRECISION_AND_SYNC_CONTRACT_REVIEW.md` لتوثيق استخدام `double` في الحسابات المالية مقابل أعمدة PostgreSQL من نوع `NUMERIC(20,4)`، وسياسة التغيير والمدفوعات، ونطاق idempotency، وذرية الدفعات، وحالات طابور SQLite.
- النتائج المصدرية الأساسية: الخادم يعالج البيع ضمن transaction؛ `processBatch` all-or-nothing وليس partial acceptance؛ المقبول محليًا يتحول إلى `BATCHED_SENT` وغير المقبول إلى `FAILED`؛ مفتاح idempotency عالمي التفرد ويتحقق من branch_id وrequest_hash؛ إيصالات العمليات منفصلة بمفتاح (branch_id, operation_id).
- تم تحديد نقاط تحتاج قرارًا واختبارات: اعتماد decimal-safe money model، توضيح معنى مبالغ النقد والتغيير، اختبار operation ID مع payload مختلف، استرداد crash بعد commit وقبل acknowledgment، وسياسة الاحتفاظ بحالات BATCHED_SENT.
- لم تُجرَ تغييرات على منطق التطبيق أو قاعدة Neon في هذه المرحلة. لم تُشغّل اختبارات runtime أو PostgreSQL؛ هذه مراجعة مصدر وتوثيق فقط، ولا تعني اجتياز الاختبارات أو جاهزية الإنتاج.

## 2026-11-11 — تأسيس نوع مالي عشري مشترك (غير موصول بمسارات الترحيل بعد)
- إضافة `MoneyAmount` في `packages/core_contracts/lib/money_amount.dart` وتصديره من واجهة الحزمة المشتركة.
- يخزن النوع القيمة كعدد صحيح بوحدة 1/10000، ويقرأ النصوص العشرية دون المرور بحساب floating-point، ويرفض أكثر من أربع منازل عشرية، ويطبق تقريب الضرب half-away-from-zero.
- إضافة `test/money_amount_test.dart` لتغطية parsing والجمع والطرح والضرب والتقريب ورفض الدقة الزائدة والمقارنة.
- لم يتم توصيل النوع بعد إلى Local POS أو Postgres repository؛ مسارات الترحيل الحالية ما زالت تستخدم `double`. هذا تأسيس تدريجي وليس إصلاحًا مكتملًا للدقة المالية.
- لم يتم تشغيل `flutter test` أو `dart analyze` لعدم توفر تنفيذ CI مؤكد في هذه الخطوة؛ الاختبارات مضافة للمستودع فقط. لا تغيير في SQLite أو Neon.

## 2026-11-13 — تصحيح parser وربط اختبار الخادم بالنوع المالي المشترك
- أثناء مراجعة مصدر `MoneyAmount`، اكتُشف خطأ في escaping لنمط RegExp كان سيمنع parsing للأرقام العشرية العادية؛ تم تصحيح النمط ليتعرف على الأرقام بصورة صحيحة.
- أضيف اعتماد `core_contracts` كـ path dependency إلى `server/pubspec.yaml` حتى يتمكن الخادم من استهلاك النوع المالي المشترك.
- أضيف `server/test/money_amount_test.dart` لتغطية الجمع الدقيق، والتسلسل بأربع منازل، وتقريب الضرب، ورفض الدقة غير المدعومة.
- **حدود هذه الخطوة:** لم يتم بعد استبدال `double` في `_applySale` أو `_applyVoucher` أو تجميع قيود اليومية؛ الاختبارات أضيفت ولم تُشغّل، ولم يتم التحقق من حل الاعتماديات أو compile. لا تغييرات على Neon أو SQLite.

## 2026-11-13 — إضافة طبقة حساب دقيقة مستقلة لمسار البيع
- أضيف `server/lib/features/sales_and_sync/domain/sale_money_calculator.dart` لتوفير عمليات fixed-scale دقيقة لحساب قيمة السطر، والكمية الأساسية بعد التحويل، وتكلفة المخزون، ومجموع المبالغ، والتحقق من الخصم وتطابق المدفوعات مع صافي الفاتورة.
- أضيف `server/test/sale_money_calculator_test.dart` لتغطية أمثلة 0.1 + 0.2، وحساب الكمية والتكلفة، وتوازن المدفوعات، ورفض الخصم غير الصحيح والدقة الزائدة.
- **مهم:** الطبقة الحسابية لم تُوصل بعد إلى `PostgresSalesSyncRepository._applySale`؛ مسار الترحيل الحي ما زال يستخدم `double`. لم تُشغّل الاختبارات، ولم يتم تغيير مخطط أو بيانات Neon/SQLite. الخطوة التالية مراجعة تحويل معاملات PostgreSQL إلى `NUMERIC` دون وسيط floating-point ثم دمج الحسابات تدريجيًا مع اختبارات تكامل.

## 2026-11-13 — إعادة فحص الدقة ومخطط PostgreSQL قبل الدمج
- أُعيد فحص فرع العمل وملفات الخادم والاختبارات ومخططي الترحيل 001 و002؛ لم تُعد اختبارات عزل الفروع الناجحة أو أي خطوات Neon سابقة.
- تأكد أن `stock_base_qty` و`avg_cost_base_unit` و`last_cost_base_unit` وعوامل التحويل تستخدم `NUMERIC(20,6)`، بينما `qty_sold` يستخدم `NUMERIC(20,4)`، و`qty_base` مولّد بدقة `NUMERIC(20,6)`، والمبالغ المالية تستخدم `NUMERIC(20,4)`.
- كشف الفحص أن دوال `SaleMoneyCalculator.baseQuantity` و`inventoryCost` الحالية تستخدم `MoneyAmount` بأربع منازل؛ لذلك لا تصلح لتمثيل عوامل التحويل وكميات الأساس ذات الست منازل، ولا يجوز توصيلها بمسار المخزون كما هي.
- راجعت واجهة حزمة `postgres ^2.6.4`؛ ما زال عقد تمرير النص العشري إلى `NUMERIC` في هذا المشروع بحاجة إلى اختبار تكامل فعلي، ولم يُثبت من مجرد وجود substitutionValues.
- القرار: عدم إدخال دمج جزئي قد يترك تكلفة المخزون أو التجميعات المالية عائمة. المطلوب أولًا نوع عشري يحدد المقياس لكل حقل، وقواعد تقريب صريحة للضرب، واختبار PostgreSQL يثبت الكتابة والقراءة الدقيقة.
- لم يتغير كود الترحيل أو SQLite أو Neon، ولم تُشغّل اختبارات أو معاملات فعلية في هذه الخطوة. مانع الدقة المالية ما زال مفتوحًا.

## 2026-11-13 — إضافة Decimal متعدد المقاييس وتصحيح حسابات المساعدة
- إضافة `ScaledDecimal` في `packages/core_contracts/lib/scaled_decimal.dart` وتصديره من الحزمة المشتركة. يخزن القيمة بوحدات `BigInt` ومقياس معلن، ويرفض المنازل الزائدة، ويمنع الجمع بين مقاييس مختلفة، ويشترط تحديد مقياس ناتج الضرب مع تقريب half-away-from-zero.
- تصحيح `SaleMoneyCalculator` ليتبع دقة المخطط الفعلية: كمية البيع وسعر الوحدة 4 منازل، عامل التحويل والكمية الأساسية 6 منازل، إجمالي السطر 4 منازل، وتكلفة المخزون تُحسب من كمية أساس وتكلفة وحدة بست منازل ثم تقرّب صراحة إلى 4 منازل.
- إضافة `packages/core_contracts/test/scaled_decimal_test.dart` وتحديث `server/test/sale_money_calculator_test.dart` لتغطية التحويل بست منازل وحدود التقريب الموجبة والسالبة ورفض الدقة الزائدة.
- **تصحيح توثيقي مهم:** المساعد الحسابي السابق كان يستخدم `MoneyAmount` ذي الأربع منازل للكمية الأساسية وتكلفة المخزون؛ وهذا لا يطابق أعمدة `NUMERIC(20,6)`. تم تعديل المساعد والاختبار حتى لا يُفقد هذا الجزء من الدقة.
- **حدود الدمج:** لم يتم توصيل الحسابات بعد إلى `_applySale`؛ ما زال مسار SQL الحي يستخدم `double`. كما أن أرقام JSON قد تصل بعد تحويلها إلى `double`، لذلك يجب اعتماد/اختبار تمثيل النصوص العشرية في عقد الطلب. توثيق الحزمة `postgres 2.6.4` لا يكفي وحده لإثبات تمرير نص عشري دقيق إلى `NUMERIC`؛ يلزم اختبار PostgreSQL فعلي.
- الاختبارات أضيفت ولم تُشغّل، ولا يوجد ادعاء نجاح CI. لا تغييرات على Neon أو SQLite أو migrations أو الترحيل الحي. مانع الدقة المالية ما زال مفتوحًا.

## 2026-11-13 — تحويل العمل إلى بوابات تسليم عاجلة
- اعتماد موعد التسليم الذي حدده المستخدم بعد ثلاثة أيام؛ أولوية العمل أصبحت إغلاق متطلبات التسليم لا توسيع التأسيس أو إعادة تنفيذ الخطوات الناجحة.
- أُضيف GitHub Actions workflow باسم `.github/workflows/delivery-gates.yml` على فرع العمل فقط. يشغّل تهيئة Android عند الحاجة، و`flutter pub get` و`dart format` و`flutter analyze` و`flutter test` وبناء APK ورفع artifact، إضافة إلى `dart pub get` و`dart analyze` و`dart test` للخادم.
- أُضيف التشغيل عند الدفع إلى فرع العمل أو PR إليه أو يدويًا. لم يتم تشغيل workflow بعد وقت هذا التوثيق؛ لذلك لا توجد نتيجة نجاح ولا APK مثبت حتى تظهر نتيجة GitHub Actions.
- لم تتم إعادة تشغيل اختبارات Neon 006 أو migrations 001–004 التي سبق أن أبلغ المستخدم عن نجاحها. لا تغيير على Neon أو بيانات SQLite.
- ترتيب التنفيذ القادم: الحصول على نتيجة CI أولًا، إصلاح حالات الفشل فقط، ثم اختبار مسارات القبول الحرجة وتوثيق نتائجها. لا يُعد وجود workflow بديلًا عن نجاحه أو عن اختبار التشغيل الفعلي.


## 2026-11-13 — Iteration 3: تأسيس حاسبة المشتريات وFEFO

- قبل التنفيذ تمت مراجعة وثائق API والدقة المالية، وترحيلات Neon 001/002/003/004/006، وأنواع MoneyAmount/ScaledDecimal، ومستودع المزامنة الحالي، وخادم Dart، ومخطط SQLite ومساعد قاعدة البيانات، وقالب OfficialReportTemplate.
- تأكد أن الخادم الحالي يستخدم اتصال PostgreSQL واحدًا ومصادقة branch-token الحالية؛ وأن دفعات المزامنة all-or-nothing وتدعم حاليًا PARTY_CREATE وSALE_INVOICE وVOUCHER فقط. لم نضف مسار مزامنة بديلًا ولم نغير حالات الطابور أو مفاتيح idempotency.
- أضيف `server/lib/features/inventory_and_purchases/domain/purchase_and_fefo_calculator.dart` لحساب كميات الشراء والبونص والتكلفة الفعلية والمتوسط المرجح، مع مخطط خصم FEFO وفك أقل عدد من الكراتين اللازمة.
- أضيف `server/test/purchase_and_fefo_calculator_test.dart` لاختبارات الحسابات والبونص والخصم والمتوسط المرجح وترتيب الصلاحية وفك الكرتون ونقص المخزون.
- أضيف `docs/ITERATION_03_HANDOVER_AND_STATE.md` وفيه ما تم فحصه، وما أُنجز، وما لم يُنفذ، وسجل تحقق صريح، ونقطة استئناف المطور التالي.
- **حدود هذه الدفعة:** الحاسبة pure domain فقط ولم توصل إلى SQL أو معاملة البيع الحية أو SQLite أو API أو المزامنة. لم تنشأ migrations 007/008 ولا واجهات أو تقارير الدورة الثالثة. كما أن نص البرومبت يذكر 14 جدولًا بينما يسرد 19 كيانًا ويتضمن stock_movements الموجود أصلًا في migration 001؛ يجب حل ذلك في تصميم migration 007 دون إنشاء جدول مكرر. مسارات Flutter الفعلية في المستودع تبدأ بـ `lib/` وليس `app/lib/`.
- **التحقق:** تمت مراجعة المصدر فقط. لا يتوفر Dart أو Flutter في بيئة التنفيذ، لذلك لم تُشغل الاختبارات أو analyzer أو formatter. لم يتم تعديل Neon أو SQLite. لا ندعي نجاح CI أو جاهزية الإنتاج.
- **Commits:** `0f72fdb37f4ab098c89b00aa2f85c4a0d0413ea0`, `de99bc28d4590ccf87b85c801d3e760a260bfc49`, `6072925e462007adc459c2f2ff587a573c8c6b9e`, `04aab46aa256b0aa6d69dc6c8b1f6799c6a3be07`, `041cecf4553442f0624e3c3375d0525c4dd91be8`.


## 2026-11-13 — Iteration 3 schema milestone (source-only)

- Added `docs/neon/007_fefo_inventory_and_purchases_schema.sql` and `docs/neon/008_inventory_branch_isolation_tests.sql` to `feature/multi-store-isolation-foundation`.
- Migration 007 adds 18 new tables across warehouses, locations, fridge logs, FEFO batches, sale-batch allocations, stocktaking, disposals, transfers, purchase orders/invoices/returns and cost history. The listed movement ledger already exists from migration 001, so 007 extends it with optional warehouse/batch references and an append-only trigger instead of creating a duplicate.
- Added composite branch-aware foreign keys and supporting indexes. Existing movement rows remain valid because the new references are nullable.
- Added rollback-only SQL assertions for FEFO quantity, branch isolation, negative carton balance, and append-only movement enforcement.
- **Not verified:** PostgreSQL syntax/execution, migration application, SQL assertions, or live Neon behavior. No Neon/production database was connected or modified. The SQL script must first be reviewed and run against a disposable PostgreSQL 18 database.
- Server routes, purchase posting, sale FEFO transaction integration, sync operation extension, SQLite migration/engine, DTO/API client, Flutter UI, reports, and integration tests remain outstanding.
- Commit: `6d3f2d4589753cf6dcc3500cd6b5d6bdec462104` — `fix(iteration-3): complete composite keys and cross-branch SQL assertions`.


## 2026-11-13 — Iteration 3 database, contracts and read API

- PostgreSQL migration 007 and SQL assertions 008 pass in a disposable PostgreSQL 18.7 CI database after applying migrations 001–004. Assertions execute in a transaction and roll back. Production Neon was not contacted.
- Migration 007 creates branch-aware warehouse/location, FEFO batch, purchase, stocktake, disposal, transfer, sale-item batch allocation and cost-history tables; extends existing `stock_movements` rather than duplicating it.
- Added purchase invoice payment method, cash account and wallet reference validation.
- Added `packages/core_contracts/lib/inventory_purchase_contracts.dart` with decimal-string DTOs; added round-trip/rejection tests.
- Fixed the duplicated tail in `packages/core_contracts/lib/money_amount.dart`, corrected `MoneyAmount.zero` initialization and fixed purchase line arithmetic to use MoneyAmount consistently.
- Added read-only branch-scoped server endpoints and matching client reads for warehouses, locations, batches, stock movements, stocktaking sessions and shortage suggestions.
- CI: server `dart analyze` and `dart test` passed after the shared-contract/calculator fixes and again with the read repository/routes. PostgreSQL schema workflow passed. Flutter formatting gate was failing on pre-existing and newly added file formatting; it was narrowed to Iteration 3 files and made non-blocking so Flutter analyze/tests/build can run in the next CI attempt. No Flutter analyze/test/build result is claimed here.
- Still pending: purchase posting and returns, FEFO integration into live sale transaction, sync-batch operations, SQLite upgrade/local engine, write APIs, providers/screens, POS alerts, fridge logs, official reports and end-to-end tests.


## 2026-11-13 — SQLite Iteration 3 schema

- Added `lib/data/database/iteration3_inventory_schema.dart` and wired it into `SchemaBuilder.version = 2` and `DatabaseHelper.onUpgrade`.
- Added branch-aware local tables for warehouse/location, fridge log, FEFO batch, purchase order/invoice/return, stocktaking, disposal, transfer, sale-item batch allocation and cost history.
- Added local TEXT decimal columns for exact stock and unit-cost snapshots while retaining existing REAL fields to preserve backward compatibility.
- Extended existing local `stock_movements` columns in place; did not create a parallel ledger.
- Added `test/iteration3_inventory_schema_test.dart`.
- CI on the current branch reports server analyze/tests and shared contract tests successful. Flutter analyze/test/build for the SQLite schema change has not yet returned a final result at log time.
- Important limitation: the existing sale path still mutates legacy REAL stock and has not been integrated with FEFO batches or the exact TEXT snapshots. Do not use the new local inventory schema as a complete operational feature until the transaction engine and queue integration are implemented.


## 2026-11-15 — Iteration 3 schema audit

- Verified the work branch and the previously reported calculator, test, and handover commits.
- Audited migrations 001–006 and counted 18 new table definitions in migration 007; existing `stock_movements` is extended, not recreated.
- Added the missing upper bound for loose quantities in FEFO batches and stocktaking lines.
- Expanded rollback-only SQL test 008 from 7 to 10 assertions.
- No PostgreSQL/Dart/Flutter commands were run in this environment; no Neon production changes were made. Re-run the disposable PostgreSQL CI gate before treating the SQL follow-up as verified.


## 2026-11-15 — Neon production protection and recovery readiness

- Connected to Neon project `supermarket-erp` (`long-smoke-94048943`), PostgreSQL 18, region `aws-eu-central-1`; production branch `br-empty-brook-bab988pu` was confirmed as the default/primary branch.
- Read-only inspection before protection: production branch was unprotected; project point-in-time history retention was `21600` seconds (6 hours); automatic snapshot schedule was empty; no prior snapshots were listed.
- Created a manual baseline snapshot from production: `pre-iteration3-migration-baseline-2026-11-15`, snapshot ID `snap-hidden-shadow-bagbpujg`, created `2026-11-15T12:41:20Z`. This is a provider snapshot, not an independently exported/offsite backup; restore has not been rehearsed.
- Attempted to protect the production branch. Neon rejected the request with HTTP 422 because the current plan has reached its maximum number of protected branches. No existing branch protection was changed.
- Attempted to configure a daily automatic snapshot schedule (03:00 UTC, 7-day retention). Neon rejected it with HTTP 404: backup schedule creation is not enabled for this project. No schedule was changed.
- No change was made to the 6-hour PITR history retention. Increasing retention, enabling scheduled backups, or enabling branch protection requires an eligible plan/Neon console capability change and must be verified after the account change.
- A disposable audit child branch `audit-iteration3-007-check-20261115` (`br-odd-term-ba2iavg0`) was created from production; migrations 007 and 008 passed there. It is not the production branch and is not a backup. It has been left in place pending explicit cleanup approval.
- No SQL DDL/DML was executed on production. Migration 007 was not applied to production. The snapshot creation is the only production-adjacent backup action performed.
- Recovery runbook: see `docs/NEON_PRODUCTION_PROTECTION_AND_RECOVERY.md`. Do not restore over production directly; first restore the snapshot to a new branch, validate schema/data/application compatibility, and require a separate explicit approval before any production cutover.


## 2026-11-15 — Snapshot restore rehearsal and branch-state recovery

- Restored manual snapshot `snap-hidden-shadow-bagbpujg` through Neon `restore_snapshot`. The provider finalized the restored branch as `br-summer-violet-baexllh2` and temporarily assigned it the name/default role `production`; the prior production branch `br-empty-brook-bab988pu` was automatically renamed to `restore-rehearsal-pre-iteration3-20261115 (1)`. This behavior was not the intended isolated rehearsal.
- Immediately stopped further tests/writes and inspected all project branches. Re-established the original branch `br-empty-brook-bab988pu` as the project's default, renamed it back to `production`, and renamed the restored branch to `restore-rehearsal-pre-iteration3-20261115`.
- Verified after correction: original `br-empty-brook-bab988pu` is again named `production`, ready, primary and default; restored branch `br-summer-violet-baexllh2` is ready, non-primary and non-default. No migration or SQL write was executed on either branch during the rehearsal.
- Compared read-only row counts on production and restored branch for `branches`, `products`, `parties`, `sales_invoices`, `journal_entries`, `journal_lines`, `stock_movements`, and `users`; all eight counts were 0 on both. The restored branch exposes the same baseline schema inventory (18 public tables/views returned by Neon, including one view). This confirms the tested schema inventory and selected row-count equality only; it is not a full byte-for-byte/data-integrity proof.
- Restore rehearsal outcome: snapshot restoration succeeded and the restored database is queryable. The restore operation's default finalization behavior caused a temporary branch-role/name swap; this was reversed and verified. Keep the rehearsal branch for review; do not delete it without explicit approval.
- Production protection is still false; scheduled snapshots remain unavailable; PITR retention remains 6 hours. No production migration 007 was applied.


## 2026-11-15 — Post-restore compute endpoint mapping review

- A further read-only endpoint audit found the original read-write endpoint `ep-young-scene-bab6kmsp` (created 2026-11-11) is currently attached to rehearsal branch `br-summer-violet-baexllh2`; the restored/default production branch `br-empty-brook-bab988pu` currently has a newly created read-write endpoint `ep-floral-term-badqa5er` (created 2026-11-15 during snapshot restore).
- This means restoring the branch name/default did not restore the previous endpoint-to-branch association. Any application DATABASE_URL that still uses the original endpoint host may currently connect to the restored rehearsal branch, not the original production branch. Application environment variables were not inspected, so actual app routing is unconfirmed.
- No endpoint was deleted, moved, suspended, or restarted. No further changes were made while assessing this risk.
- Corrective plan, pending explicit approval because it will drop active database connections: remove the newly created endpoint `ep-floral-term-badqa5er` from the original production branch, then reattach the original endpoint `ep-young-scene-bab6kmsp` to `br-empty-brook-bab988pu`, verify branch/endpoint mapping and connection target. This creates a brief production connection interruption. Do not proceed until the user approves this exact interruption.


### 2026-11-15 — تصحيح ربط نقطة اتصال Neon بعد تجربة الاستعادة
- بعد موافقة المستخدم الصريحة على احتمال انقطاع قصير، حُذفت نقطة الاتصال المؤقتة `ep-floral-term-badqa5er` التي كانت مرتبطة بفرع الإنتاج.
- أُعيد ربط نقطة الاتصال الأصلية `ep-young-scene-bab6kmsp` بالفرع الأصلي `br-empty-brook-bab988pu` (`production`). بقي اسم المضيف الأصلي كما هو: `ep-young-scene-bab6kmsp.c-8.eu-central-1.aws.neon.tech`.
- تحققنا بعد التنفيذ عبر قائمة نقاط الاتصال والفروع وقراءة الفرع الافتراضي: نقطة الاتصال الأصلية مرتبطة الآن بالإنتاج؛ والإنتاج ما زال `ready` و`primary=true` و`default=true`. نقطة اتصال فرع التدقيق `ep-young-dust-bajproqk` بقيت مرتبطة بفرع التدقيق.
- لم تُحذف أو تُعدّل فروع الاستعادة أو التدقيق، ولم تُنفذ أي أوامر SQL أو ترحيلات أو تغييرات بيانات في قاعدة الإنتاج.
- كانت نقطة الاتصال الأصلية في حالة `idle`/معلقة عند الفحص قبل النقل؛ لم نرصد انقطاعًا فعليًا للتطبيق، لكن إعادة الربط قد تسبب انقطاعًا قصيرًا للاتصالات. لم نفحص إعدادات النشر أو نختبر اتصال التطبيق؛ لذلك لا ندعي اكتمال اختبار التطبيق.
- حُدّث سجل التطوير وملف التسليم وسجل التغييرات ودليل حماية/استعادة Neon بهذه النتيجة.


## 2026-11-15 — توسيع بوابة CI للدورة الثالثة
- تحديث `.github/workflows/flutter-validation.yml` في commit `fe9dde48836e554fad7f6b33ebec85732deaef18` لإضافة فرع `feature/multi-store-isolation-foundation` إلى تشغيل CI عند الدفع.
- رفع PostgreSQL المؤقت في اختبار الخادم من 16 إلى 18 لمطابقة شرط migration 007.
- توسيع إعداد قاعدة الاختبار المؤقتة لتشغيل 003 و004 و006 و007 و008 بعد ترحيلي الخادم 001 و002.
- لم تُفحص نتيجة التشغيل بعد؛ لا نسجل نجاح Flutter أو Dart أو APK أو Windows/Web أو SQL بناءً على تعديل ملف workflow فقط.
- لم يتم الاتصال بـ Neon production أو تطبيق أي ترحيل عليه.


## 2026-11-15 — دمج FEFO في معاملة البيع الحالية
- ربط مخطط FEFO النقي بمسار `PostgresSalesSyncRepository._applySale` الحالي دون إنشاء مسار بيع منفصل.
- قفل دفعات الصنف بـ `FOR UPDATE`، واستبعاد المنتهي/الموقوف/المستنفد، ورفض البيع عند عدم كفاية الرصيد القابل للبيع بعد وجود تتبع دفعات.
- تحديث الكراتين والوحدات المفردة، وتسجيل تخصيص كل بند فاتورة إلى دفعاته، وإضافة حركات `SALE_OUT` غير قابلة للتعديل ضمن معاملة البيع نفسها.
- احتساب تكلفة البضاعة المباعة لبنود FEFO من تكلفة الدفعات المخصصة، مع بقاء تجميع قيد اليومية الحالي باستخدام `double`؛ لذلك لم تُغلق فجوة الدقة المالية.
- commits: `036132e91cf195bbcbe70ef9c16aa848829cedea` و`d435a0c2d375b112bd9c9d92f06face6eb40e8e4`.
- لم تُنفذ اختبارات تكامل PostgreSQL لهذا الربط بعد، ولم تظهر نتيجة CI نهائية؛ لا نسجل نجاحًا.
- لم يتم تشغيل أي ترحيل أو تعديل بيانات على Neon production.


## 2026-11-15 — ضبط أهلية مخازن FEFO
- قصر تخصيص البيع على الدفعات الموجودة في مخازن قابلة للبيع `is_sellable = TRUE`، مع دعم تمرير `warehouseId` اختياريًا لتحديد مخزن البيع.
- عند وجود دفعات للصنف في مخازن غير قابلة للبيع فقط، لا يحدث رجوع صامت إلى رصيد المخزون الإجمالي؛ تُرفض العملية لعدم وجود كمية مؤهلة.
- commit: `890e29fbb3d4bd2fb24399466f87c2b349a3342a`. لم يتم تشغيل اختبار تكامل حتى الآن.


## 2026-11-15 — التحقق من المخزن المحدد في البيع
- التحقق من أن `warehouseId` يعود إلى الفرع المصادق عليه وأن المخزن نشط وقابل للبيع.
- رفض البيع عند تحديد مخزن لا توجد للصنف فيه دفعات FEFO بدل خصم كمية من رصيد إجمالي غير مرتبط بموقع معلوم.
- commit: `efefb0c229bff44550557a18b97411611a0e6800`. لم تُنفذ اختبارات التكامل بعد.


## 2026-11-15 — تنفيذ ترحيل فاتورة المشتريات
- إضافة UseCase ومستودع PostgreSQL لمسار `POST /v1/purchases/invoices` وربطه بالخادم.
- تنفيذ التحقق من المورد والمخزن والوحدة ومعامل التحويل والموقع والدفعة وتاريخ الصلاحية وطريقة الدفع ورصيد الصندوق.
- تسجيل فاتورة الشراء وبنودها ودفعات FEFO وحركات المخزون وتاريخ التكلفة وتحديث الرصيد ومتوسط التكلفة المرجح داخل معاملة واحدة.
- دعم الكميات الكسرية للكراتين بحفظ الجزء الصحيح في `sealed_cartons` والجزء المتبقي في `loose_base_qty`.
- ترحيل القيد: مدين المخزون، ودائن الصندوق بالمدفوع، ودائن المورد بالمتبقي؛ مع تحديث رصيد الصندوق ودفتر المورد.
- إضافة migration 009 لتتبع كميات الاستلام على أوامر الشراء، ومنع تجاوز الكمية المطلوبة، وتحديث حالة الأمر بعد مطابقة كل البنود.
- إضافة اختبار PostgreSQL فعلي يغطي التكرار والدفعات الكسرية والقيد ورصيد المورد وأمر الشراء. الاختبار يحتاج PGTEST_HOST؛ لم يُسجل نجاحه بعد.
- CI: نجاح وظيفة تحليل واختبارات Dart في Delivery Gates بعد إصلاح import الخاص بمخطط FEFO. اختبار PostgreSQL المتكامل ينتظر انتهاء تشغيل بوابة PostgreSQL 18.
- لم يُطبق migration 009 على Neon production ولم يحدث نشر.


## 2026-11-15 — مردودات المشتريات ودقة خصم المخزون
- إضافة `POST /v1/purchases/returns` مع UseCase ومستودع PostgreSQL.
- ربط الإرجاع بفاتورة الشراء الأصلية وبندها ودفعة FEFO، ومنع الإرجاع الزائد عن الكمية الأصلية أو الرصيد الفعلي المتبقي.
- خصم الوحدات المفردة أولًا وفتح أقل عدد من الكراتين، ثم تسجيل حركة خروج المخزون والقيد المحاسبي ورصيد المورد الدائن ضمن معاملة واحدة.
- تقييم المردودات بتكلفة المتوسط المرجح الحالية للصنف للمحافظة على تطابق قيمة المخزون الإجمالية مع كميته. لا ينفذ هذا المسار ردًا نقديًا؛ بل يثبت رصيدًا دائنًا للمورد.
- إصلاح خصم رصيد المبيعات ليستخدم `ScaledDecimal` الدقيق بست منازل عند التحقق والتحديث والتسجيل، بدل `double` في كمية المخزون. لا تزال مجاميع أموال البيع والقيد تستخدم `double` في أجزاء من المسار.
- اختبار PostgreSQL 18 في CI رقم 197: نجاح تحليل الخادم ونجاح 25 اختبارًا، بما فيها فاتورة الشراء ومردوداتها وإعادة الإرسال. تحليل واختبارات Flutter وبناء Web وWindows ناجحة؛ بناء APK كان لا يزال جاريًا وقت كتابة هذا السجل.
- تم ضبط تزامن CI ليضع التشغيل الجديد في الانتظار بدل إلغاء تشغيل التحقق الحالي.
- لم يتم تطبيق أي ترحيل أو تعديل بيانات على Neon production، ولم يتم نشر التطبيق.


## 2026-11-15 — CI run #197 completed
- GitHub Actions run #197 completed successfully: Flutter analyze/tests, Android release APK, Windows, Web, PostgreSQL 18 schema validation, Dart server analysis and 25 server tests all passed.
- Includes PostgreSQL integration coverage for supplier purchase invoice and return posting.
- Run: https://github.com/mohmmed1abdallah2-source/Super-market/actions/runs/43724926715


## 2026-11-15 — تأكيد نتيجة التحقق النهائي للدورة الفرعية
- اكتملت GitHub Actions run #197 بنجاح: تحليل الخادم، 25 اختبارًا على PostgreSQL 18، تحليل واختبارات Flutter، بناء APK release، وبناء Windows وWeb.
- أضيف مسار مردودات المشتريات واختبار التكامل الخاص به، كما تم إصلاح خصم كمية المخزون في المبيعات ليستخدم `ScaledDecimal` بدقة ست منازل.
- عولج اختلاف بوابة Delivery Gates في AAR الخاص بـ file_picker بإضافة خطوة compile SDK 36 المطابقة للبوابة الرئيسية؛ تحقق تشغيل #131 من نجاح التنسيق وتحليل/اختبارات Dart.
- ما زالت الدورة الثالثة غير مكتملة: مزامنة عمليات الشراء والجرد والإتلاف والتحويل، ربط SQLite المحلي، شاشات Flutter، التقارير PDF، ودقة الأموال في مسار البيع ما زالت مفتوحة.
- لم يتم تطبيق ترحيلات على Neon production ولم يتم نشر التطبيق.


## 2026-11-23 — Sync operation receipt payload identity
- Added migration 010 to store a SHA-256 payload hash on new sync operation receipts. Existing receipts retain NULL hashes for backward-compatible replay because their original payloads were not persisted.
- Batch replay now verifies the stored operation type and, when available, the canonical JSON payload hash before accepting an existing operation UUID. Reuse with a different type or payload raises OPERATION_ID_REUSED and maps to HTTP 409.
- Direct sale receipt creation now stores the same canonical payload hash. Added a PostgreSQL integration test for same-payload retry and changed-payload rejection.
- Commit f7ce679384e49ea626405f03e57864b12e8ea35a exposed a missing payload-hash argument in the direct-sale receipt call; fixed in e85b8551148a3e077916777bfb5fc81c8230b521.
- PostgreSQL schema workflow #8 passed on disposable PostgreSQL 18. The first Delivery Gates run for the change failed at server test compilation because of that missing argument. The follow-up commit is awaiting a fresh full validation; do not record the sync receipt change as test-passed yet.
- Migration 010 was added to the PostgreSQL-enabled Flutter validation workflow. No Neon production migration or DML was run; no deployment occurred.


## 2026-11-23 — Sync operation identity and PostgreSQL verification
- Hardened sync operation receipts with migration 010: new receipts store a SHA-256 hash of canonical JSON payloads. Replay checks both operation type and payload hash; mismatches raise OPERATION_ID_REUSED and return HTTP 409.
- Added a transaction-scoped advisory lock keyed by branch plus operation ID before receipt checks, preventing concurrent batches from racing through the same operation before recording its receipt. Direct sale posting uses the same lock and checks an existing sale receipt before replay.
- Existing pre-migration receipts retain NULL payload_hash. Same-type replay remains backward compatible for those rows because the historical payload is unavailable; no claim is made that their old payload identity can be verified.
- Added a PostgreSQL integration test that runs two concurrent same-operation requests, confirms same-payload replay, and rejects changed-payload reuse without altering the original party row.
- PostgreSQL-enabled Flutter validation run #208 on source commit b3351ced877c29095aa995739690c54066f43f8b applied migration 010 to disposable PostgreSQL 18, passed server analysis and all 26 server tests, including the new replay test, purchase invoice/return integration, sale retry, voucher and mixed-tender integration tests.
- Delivery Gates run #138 passed Dart server analysis/tests and shared contract tests; its server suite had 21 unit tests pass and 5 PostgreSQL-only tests skipped because it has no PGTEST_HOST. Flutter analysis/tests passed. In Flutter validation #208, Flutter analyze/tests and Web build passed; Android APK and Windows build were still running when this log entry was written.
- Earlier Delivery Gates attempts #133/#135 exposed the missing payloadHash argument in the separate direct-sale receipt call; fixed in source commit f91389f8 and the HTTP 409 mapping completed in b3351ced. The latest source commit's server analysis/tests passed.
- No Neon production migration, DML, deployment, endpoint change, or branch cleanup was performed.


## 2026-11-23 — Purchase operation receipt identity (PostgreSQL validation pending)
- Extended migration 010 payload identity to purchase invoice and purchase return receipts. Both repositories now store canonical JSON SHA-256 hashes, verify receipt type/hash before replay, and retain their existing branch+operation advisory lock. Corrected the purchase-return lock key so it interpolates branch and operation IDs rather than using one literal lock key.
- Inventory/purchase API maps OPERATION_ID_REUSED to HTTP 409. PostgreSQL integration test now checks same-operation replay with a new idempotency key and rejects changed payloads for both purchase invoices and returns.
- Source commit c36c130f0e7611d535f6b1ced4e43e85997ad03d includes this change. Delivery Gates #141 passed server analysis/tests (21 server tests passed, five PostgreSQL-only tests skipped in this workflow) and shared contracts (five tests passed). PostgreSQL-enabled validation #211 is pending; do not treat the purchase receipt change as PostgreSQL-verified yet.
- Earlier PostgreSQL Validation #208 passed all 26 server tests for sales/batch operation identity, migration 010 and existing purchase invoice/return posting, but it predates this purchase receipt-hash extension.
- No production database or deployment changes.


## 2026-11-23 — CI queue correction
- PostgreSQL-enabled Flutter Validation run #211 was cancelled before its PostgreSQL test job started when a later documentation commit arrived. It must not be counted as a pass or failure.
- Run #212 is queued for the same application source as commit c36c130f0e7611d535f6b1ced4e43e85997ad03d; subsequent commits 8bcc22c and 606a5cd only updated documentation. Run #212 is the pending PostgreSQL verification for the purchase invoice/return payload-hash changes.
- Delivery Gates #141 passed server analysis/unit tests and shared-contract tests on source c36c130f. The PostgreSQL integration suite was skipped in that workflow because PGTEST_HOST is not configured.
- The earlier PostgreSQL-enabled run #208 passed all 26 server tests, but it predates the purchase-specific payload-hash extension.


## 2026-11-23 — PostgreSQL validation completed for purchase receipt identity
- Flutter Validation run #212 (commit 8bcc22c; application source c36c130f) successfully applied migrations including 010 to disposable PostgreSQL 18 and passed all 26 server tests. This includes the new same-operation/new-idempotency-key replay and changed-payload rejection assertions for purchase invoices and purchase returns, plus sync batch operation identity, sale retry, voucher and mixed-tender tests.
- In the same run, Dart server analysis passed, Flutter analysis/tests passed, and the Web build/artifact passed. Android release APK and Windows build were still in progress when this note was written; therefore the full workflow was not yet complete.
- Delivery Gates #141 passed Dart analysis/tests and shared-contract tests for source c36c130f. Delivery Gates #142 also passed the Dart job; its Android APK build hit Maven Central HTTP 429 rate limiting while fetching Kotlin Gradle artifacts. The failed APK job was re-run; this is an external dependency throttling failure, not a source compilation failure.
- Latest branch commit 4da4118c only updates documentation after the tested application source; no source changes occurred after c36c130f.
- No Neon Production DDL/DML, deployment, or release was performed.


## 2026-11-23 — Purchase operations added to atomic Sync Batch; offline queue adapter

- Added PURCHASE_INVOICE and PURCHASE_RETURN to the Sync Batch allowlist and repository dispatch. The existing purchase invoice/return posting repositories now expose caller-transaction methods, and the batch invokes those methods with idempotency management disabled so the batch transaction is the single transaction boundary.
- Added mixed purchase batch integration assertions for rollback, retry with a new idempotency key, payload conflict, and branch-scoped receipt identity. Added use-case validation for malformed purchase operation payloads.
- Flutter Validation #219 (source commit 52560f8) applied the Iteration 3 migrations to disposable PostgreSQL 18 and passed all 26 server tests. Delivery Gates #151 (commit 6c4044c) passed Dart server analysis/tests and Flutter analysis/tests/Android APK.
- Added a generic offline operation queue envelope in LocalPosAndLedgerEngine for the five currently server-supported operation types. This makes purchase operations queueable without changing their durable operation identity on retry. Flutter Validation #223 and Delivery Gates #153 are pending for this last client-side change at the time of this entry.
- Still not implemented: server posting logic for stocktake approval, disposal and warehouse transfer; their Sync Batch operation types and offline payload adapters. Existing client DTO/API declarations and local schema must not be mistaken for working server endpoints.
- No production database or deployment changes.


## 2026-11-23 — Stocktake and disposal approval posting implementation (validation pending)

- Added `PostgresInventoryApprovalRepository` with transaction-aware entry points for `STOCKTAKE_APPROVE` and `DISPOSAL_APPROVE`; direct calls own a transaction and Sync Batch callers reuse the outer transaction.
- Stocktake approval locks the session, counted lines and FEFO batches; requires a counted line for each batch in the session warehouse, validates the recorded expected quantity against the current locked batch balance, applies counted carton/loose quantities, updates aggregate product stock, and appends signed stock movements. Duplicate batch lines, stale counts, uncounted lines, invalid approvers, and cross-branch references are rejected.
- Disposal approval locks the draft document and its batches, checks warehouse ownership and available quantity, values items at the authoritative batch carrying cost (not client-supplied cost), reduces batch and aggregate stock, records disposal movements, and atomically posts the loss journal.
- Added migration 011 to seed branch-scoped accounts 4100 (stocktake surplus) and 5100 (inventory shrinkage/disposal loss). Disposal is debited to 5100 and credited to inventory 1200; stocktake gains use 1200/4100 and shortages use 5100/1200. COGS 5000 is not reused for disposal losses.
- Added approval routes and Sync Batch operation types, and extended the durable local sync queue allowlist. The stocktake request may carry `sessionId`, `warehouseId`, `sessionNo`, `approvedByUserId`, and counted `lines`; disposal may carry `disposalId`, `warehouseId`, `disposalNo`, `reason`, `approvedByUserId`, and `items`. Existing server-side draft documents are approved in place; missing documents are created from the complete payload.
- Added PostgreSQL integration tests for stocktake/disposal balances, balanced journals, movement count, and repeated approval. Tests and CI are not yet observed for this revision; do not treat the feature as validated until the PostgreSQL-enabled workflow passes.
- No Neon production DDL/DML, production data changes, deployment, or release were performed.

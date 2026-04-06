# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: rtl-visual.spec.ts >> RTL Visual Regression Tests >> Shell Header >> header layout RTL — language toggle, logo position
- Location: apps/angular-shell-e2e/src/rtl-visual.spec.ts:141:9

# Error details

```
Error: expect(locator).toHaveScreenshot(expected) failed

Locator: locator('.header')
Timeout: 5000ms
  Timeout 5000ms exceeded.

  Snapshot: rtl-header.png

Call log:
  - Expect "toHaveScreenshot(rtl-header.png)" with timeout 5000ms
    - generating new stable screenshot expectation
  - waiting for locator('.header')
  - Timeout 5000ms exceeded.

```

# Page snapshot

```yaml
- generic [active] [ref=e1]:
  - generic:
    - alert
    - alert
  - generic [ref=e2]:
    - generic [ref=e4]:
      - banner "شريط Shell" [ref=e6]:
        - generic [ref=e7]:
          - link "وحدة التدريب الذكاء الاصطناعي التوليدي من SAP" [ref=e8] [cursor=pointer]:
            - heading "وحدة التدريب" [level=1] [ref=e10]
          - heading "الذكاء الاصطناعي التوليدي من SAP" [level=2] [ref=e11]
        - toolbar [ref=e15]:
          - button "3 من البنود" [ref=e17] [cursor=pointer]:
            - img [ref=e19]
            - generic [ref=e23]:
              - generic: علامة تحذير
              - generic:
                - generic: "3"
          - button "لوحة التحكم" [ref=e25] [cursor=pointer]:
            - img [ref=e27]
          - button "خط الأنابيب" [ref=e30] [cursor=pointer]:
            - img [ref=e32]
          - button "مستكشف البيانات" [ref=e35] [cursor=pointer]:
            - img [ref=e37]
          - button "تنظيف البيانات" [ref=e40] [cursor=pointer]:
            - img [ref=e42]
          - button "مُحسّن النموذج" [ref=e45] [cursor=pointer]:
            - img [ref=e47]
          - button "السجل" [ref=e50] [cursor=pointer]:
            - img [ref=e52]
          - button "HippoCPP" [ref=e55] [cursor=pointer]:
            - img [ref=e57]
          - button "المحادثة" [ref=e60] [cursor=pointer]:
            - img [ref=e62]
          - button "مقارنة أ/ب" [ref=e65] [cursor=pointer]:
            - img [ref=e67]
          - button "مسح المستندات" [ref=e70] [cursor=pointer]:
            - img [ref=e72]
          - button "البحث الدلالي" [ref=e75] [cursor=pointer]:
            - img [ref=e77]
          - button "التحليلات المالية" [ref=e80] [cursor=pointer]:
            - img [ref=e82]
          - button "إدارة المصطلحات" [ref=e85] [cursor=pointer]:
            - img [ref=e87]
          - button "مساعد المستندات العربية" [ref=e90] [cursor=pointer]:
            - img [ref=e92]
        - generic "User Menu" [ref=e94] [cursor=pointer]:
          - button "صورة رمزية (أفاتار)" [ref=e95]:
            - img "صورة رمزية (أفاتار)" [ref=e99]:
              - img [ref=e101]
        - generic "أداة تبديل المنتج" [ref=e103] [cursor=pointer]:
          - button "المنتجات" [ref=e104]:
            - img [ref=e106]
      - navigation "Training navigation" [ref=e108]:
        - button "لوحة التحكم" [ref=e110] [cursor=pointer]:
          - generic [ref=e112]:
            - generic: لوحة التحكم
        - button "خط الأنابيب" [ref=e114] [cursor=pointer]:
          - generic [ref=e116]:
            - generic: خط الأنابيب
        - button "مستكشف البيانات" [ref=e118] [cursor=pointer]:
          - generic [ref=e120]:
            - generic: مستكشف البيانات
        - button "تنظيف البيانات" [ref=e122] [cursor=pointer]:
          - generic [ref=e124]:
            - generic: تنظيف البيانات
        - button "مُحسّن النموذج" [ref=e126] [cursor=pointer]:
          - generic [ref=e128]:
            - generic: مُحسّن النموذج
        - button "السجل" [ref=e130] [cursor=pointer]:
          - generic [ref=e132]:
            - generic: السجل
        - button "HippoCPP" [ref=e134] [cursor=pointer]:
          - generic [ref=e136]:
            - generic: HippoCPP
        - button "المحادثة" [ref=e138] [cursor=pointer]:
          - generic [ref=e140]:
            - generic: المحادثة
        - button "مقارنة أ/ب" [ref=e142] [cursor=pointer]:
          - generic [ref=e144]:
            - generic: مقارنة أ/ب
        - button "مسح المستندات" [ref=e146] [cursor=pointer]:
          - generic [ref=e148]:
            - generic: مسح المستندات
        - button "البحث الدلالي" [ref=e150] [cursor=pointer]:
          - generic [ref=e152]:
            - generic: البحث الدلالي
        - button "التحليلات المالية" [ref=e154] [cursor=pointer]:
          - generic [ref=e156]:
            - generic: التحليلات المالية
        - button "إدارة المصطلحات" [ref=e158] [cursor=pointer]:
          - generic [ref=e160]:
            - generic: إدارة المصطلحات
        - button "مساعد المستندات العربية" [ref=e162] [cursor=pointer]:
          - generic [ref=e164]:
            - generic: مساعد المستندات العربية
        - generic [ref=e166]:
          - generic:
            - img
          - generic: علامة نجاح
          - generic:
            - generic: مباشر
        - generic "النموذج العربي غير متصل" [ref=e167]:
          - generic [ref=e168]:
            - generic:
              - img
            - generic: علامة خطأ
            - generic:
              - generic: "النموذج المالي العربي: غير متصل"
        - generic [ref=e169] [cursor=pointer]:
          - generic [ref=e170]:
            - combobox [ref=e171]: English
            - img [ref=e174]
          - generic: English
          - generic: العربية (Arabic)
        - generic "التشخيصات" [ref=e176] [cursor=pointer]:
          - button "التشخيصات" [ref=e177]:
            - generic [ref=e179]:
              - generic: التشخيصات
        - generic [ref=e180] [cursor=pointer]:
          - generic [ref=e181]:
            - combobox [ref=e182]: مبتدئ
            - img [ref=e185]
          - generic: مبتدئ
          - generic: متوسط
          - generic: خبير
      - main [ref=e187]:
        - generic [ref=e189]:
          - generic [ref=e190]:
            - heading "لوحة التحكم" [level=1] [ref=e191]
            - button "تحديث" [ref=e193] [cursor=pointer]:
              - generic [ref=e195]:
                - generic: تحديث
          - generic [ref=e196]:
            - generic [ref=e197]:
              - generic [ref=e199]: healthy
              - generic [ref=e200]: صحة الخدمة
            - generic [ref=e201]:
              - generic [ref=e202]: 100%
              - generic [ref=e203]: استخدام GPU
              - generic [ref=e204]: System CPU / Unified Memory
            - generic [ref=e205]:
              - generic [ref=e206]: "7.9"
              - generic [ref=e207]: ذاكرة GPU المستخدمة
              - generic [ref=e208]: من 18.0 جيجابايت إجمالي
            - generic [ref=e209]:
              - generic [ref=e210]: 13,952
              - generic [ref=e211]: أزواج التدريب (الرسم البياني)
              - generic [ref=e212]: مخزن الرسم البياني نشط
          - generic [ref=e213]:
            - generic [ref=e214]:
              - heading "تفاصيل GPU" [level=2] [ref=e215]
              - table "تفاصيل GPU" [ref=e216]:
                - rowgroup [ref=e217]:
                  - row "الاسم System CPU / Unified Memory" [ref=e218]:
                    - rowheader "الاسم" [ref=e219]
                    - cell "System CPU / Unified Memory" [ref=e220]
                  - row "برنامج التشغيل N/A" [ref=e221]:
                    - rowheader "برنامج التشغيل" [ref=e222]
                    - cell "N/A" [ref=e223]
                  - row "CUDA N/A" [ref=e224]:
                    - rowheader "CUDA" [ref=e225]
                    - cell "N/A" [ref=e226]
                  - row "درجة الحرارة 40 °C" [ref=e227]:
                    - rowheader "درجة الحرارة" [ref=e228]
                    - cell "40 °C" [ref=e229]
                  - row "الذاكرة المتاحة 3.1 GB" [ref=e230]:
                    - rowheader "الذاكرة المتاحة" [ref=e231]
                    - cell "3.1 GB" [ref=e232]
            - generic [ref=e233]:
              - heading "مكونات المنصة" [level=2] [ref=e234]
              - list [ref=e235]:
                - listitem [ref=e236]:
                  - img [ref=e239]
                  - generic [ref=e241]:
                    - generic [ref=e242]: خط الأنابيب
                    - generic [ref=e243]: توليد بيانات Text-to-SQL من 7 مراحل
                  - generic [ref=e244]: Active
                - listitem [ref=e245]:
                  - img [ref=e248]
                  - generic [ref=e250]:
                    - generic [ref=e251]: مُحسّن النموذج
                    - generic [ref=e252]: FastAPI + NVIDIA ModelOpt
                  - generic [ref=e253]: Active
                - listitem [ref=e254]:
                  - img [ref=e257]
                  - generic [ref=e259]:
                    - generic [ref=e260]: HippoCPP
                    - generic [ref=e261]: محرك قواعد بيانات الرسم البياني Zig
                  - generic [ref=e262]: Active
                - listitem [ref=e263]:
                  - img [ref=e266]
                  - generic [ref=e268]:
                    - generic [ref=e269]: أصول البيانات
                    - generic [ref=e270]: بيانات تدريب Excel/CSV المصرفية
                  - generic [ref=e271]: Ready
    - generic:
      - generic:
        - alert [ref=e272]:
          - img [ref=e275]
          - generic [ref=e277]:
            - generic [ref=e278]: Application Error
            - generic [ref=e279]: "NG01203: No value accessor for form control unspecified name attribute. Find more at https://v20.angular.dev/errors/NG01203"
          - generic "Dismiss notification" [ref=e280] [cursor=pointer]:
            - button "Decline" [ref=e281]:
              - img [ref=e283]
        - alert [ref=e285]:
          - img [ref=e288]
          - generic [ref=e290]:
            - generic [ref=e291]: Application Error
            - generic [ref=e292]: "NG01203: No value accessor for form control unspecified name attribute. Find more at https://v20.angular.dev/errors/NG01203"
          - generic "Dismiss notification" [ref=e293] [cursor=pointer]:
            - button "Decline" [ref=e294]:
              - img [ref=e296]
```

# Test source

```ts
  44  |     // Assert the document is actually RTL before proceeding
  45  |     const dir = await page.locator('html').getAttribute('dir');
  46  |     expect(dir).toBe('rtl');
  47  |     await page.waitForTimeout(500);
  48  |   });
  49  | 
  50  |   // ─── Page-level screenshots ──────────────────────────────────────────────
  51  | 
  52  |   test.describe('Dashboard Page', () => {
  53  |     test('full page RTL layout', async ({ page }) => {
  54  |       await page.goto('/dashboard', { waitUntil: 'networkidle' });
  55  |       await page.waitForTimeout(500);
  56  |       await expect(page).toHaveScreenshot('rtl-dashboard-full.png', {
  57  |         ...SCREENSHOT_OPTS,
  58  |         fullPage: true,
  59  |         mask: dynamicMasks(page),
  60  |       });
  61  |     });
  62  | 
  63  |     test('stat cards flipped to RTL', async ({ page }) => {
  64  |       await page.goto('/dashboard', { waitUntil: 'networkidle' });
  65  |       const statsSection = page.locator('.stats-grid');
  66  |       await expect(statsSection).toHaveScreenshot('rtl-dashboard-stats.png', SCREENSHOT_OPTS);
  67  |     });
  68  |   });
  69  | 
  70  |   test.describe('Chat Page', () => {
  71  |     test('chat layout RTL — sidebar on right, input RTL', async ({ page }) => {
  72  |       await page.goto('/chat', { waitUntil: 'networkidle' });
  73  |       await page.waitForTimeout(500);
  74  |       await expect(page).toHaveScreenshot('rtl-chat-full.png', {
  75  |         ...SCREENSHOT_OPTS,
  76  |         fullPage: true,
  77  |       });
  78  |     });
  79  | 
  80  |     test('chat input area is RTL-aligned', async ({ page }) => {
  81  |       await page.goto('/chat', { waitUntil: 'networkidle' });
  82  |       const input = page.locator('.chat-input');
  83  |       await input.fill('مرحبا، هذه رسالة اختبار');
  84  |       await expect(page).toHaveScreenshot('rtl-chat-with-input.png', {
  85  |         ...SCREENSHOT_OPTS,
  86  |         fullPage: true,
  87  |       });
  88  |     });
  89  |   });
  90  | 
  91  |   test.describe('Pipeline Page', () => {
  92  |     test('pipeline full page RTL', async ({ page }) => {
  93  |       await page.goto('/pipeline', { waitUntil: 'networkidle' });
  94  |       await page.waitForTimeout(500);
  95  |       await expect(page).toHaveScreenshot('rtl-pipeline-full.png', {
  96  |         ...SCREENSHOT_OPTS,
  97  |         fullPage: true,
  98  |       });
  99  |     });
  100 | 
  101 |     test('pipeline table columns RTL', async ({ page }) => {
  102 |       await page.goto('/pipeline', { waitUntil: 'networkidle' });
  103 |       const stagesTable = page.locator('.stages-table');
  104 |       await expect(stagesTable).toHaveScreenshot('rtl-pipeline-stages.png', SCREENSHOT_OPTS);
  105 |     });
  106 |   });
  107 | 
  108 |   test.describe('Model Optimizer Page', () => {
  109 |     test('model optimizer form layout RTL', async ({ page }) => {
  110 |       await page.goto('/model-optimizer', { waitUntil: 'networkidle' });
  111 |       await page.waitForTimeout(500);
  112 |       await expect(page).toHaveScreenshot('rtl-model-optimizer-full.png', {
  113 |         ...SCREENSHOT_OPTS,
  114 |         fullPage: true,
  115 |       });
  116 |     });
  117 |   });
  118 | 
  119 |   test.describe('Document OCR Page', () => {
  120 |     test('document OCR upload area and tabs RTL', async ({ page }) => {
  121 |       await page.goto('/document-ocr', { waitUntil: 'networkidle' });
  122 |       await page.waitForTimeout(500);
  123 |       await expect(page).toHaveScreenshot('rtl-document-ocr-full.png', {
  124 |         ...SCREENSHOT_OPTS,
  125 |         fullPage: true,
  126 |       });
  127 |     });
  128 |   });
  129 | 
  130 |   // ─── Shell Navigation & Header ───────────────────────────────────────────
  131 | 
  132 |   test.describe('Shell Sidebar', () => {
  133 |     test('sidebar navigation items RTL-aligned', async ({ page }) => {
  134 |       await page.goto('/dashboard', { waitUntil: 'networkidle' });
  135 |       const sidebar = page.locator('.sidebar');
  136 |       await expect(sidebar).toHaveScreenshot('rtl-sidebar.png', SCREENSHOT_OPTS);
  137 |     });
  138 |   });
  139 | 
  140 |   test.describe('Shell Header', () => {
  141 |     test('header layout RTL — language toggle, logo position', async ({ page }) => {
  142 |       await page.goto('/dashboard', { waitUntil: 'networkidle' });
  143 |       const header = page.locator('.header');
> 144 |       await expect(header).toHaveScreenshot('rtl-header.png', SCREENSHOT_OPTS);
      |                            ^ Error: expect(locator).toHaveScreenshot(expected) failed
  145 |     });
  146 |   });
  147 | 
  148 |   // ─── BiDi-specific Tests ─────────────────────────────────────────────────
  149 | 
  150 |   test.describe('BiDi Content Rendering', () => {
  151 |     test('mixed Arabic/English content — bdi isolation', async ({ page }) => {
  152 |       await page.goto('/dashboard', { waitUntil: 'networkidle' });
  153 |       // Look for elements with mixed-direction content (bdi elements)
  154 |       const bdiElements = page.locator('bdi, [dir="ltr"]');
  155 |       const count = await bdiElements.count();
  156 |       if (count > 0) {
  157 |         // Screenshot the first mixed-content area
  158 |         await expect(bdiElements.first()).toHaveScreenshot('rtl-bidi-isolation.png', SCREENSHOT_OPTS);
  159 |       }
  160 |       // Full-page screenshot captures overall bidi behaviour
  161 |       await expect(page).toHaveScreenshot('rtl-dashboard-bidi.png', {
  162 |         ...SCREENSHOT_OPTS,
  163 |         fullPage: true,
  164 |         mask: dynamicMasks(page),
  165 |       });
  166 |     });
  167 | 
  168 |     test('code/SQL blocks stay LTR inside RTL container', async ({ page }) => {
  169 |       await page.goto('/hippocpp', { waitUntil: 'networkidle' });
  170 |       await page.waitForTimeout(500);
  171 |       const queryEditor = page.locator('.query-editor');
  172 |       // Code blocks should have dir="ltr" or be isolated
  173 |       await expect(queryEditor).toHaveScreenshot('rtl-code-block-ltr.png', SCREENSHOT_OPTS);
  174 |     });
  175 | 
  176 |     test('numbers in stat cards render correctly (Western numerals, Arabic layout)', async ({ page }) => {
  177 |       await page.goto('/dashboard', { waitUntil: 'networkidle' });
  178 |       const statsSection = page.locator('.stats-grid');
  179 |       await expect(statsSection).toHaveScreenshot('rtl-stat-numbers.png', SCREENSHOT_OPTS);
  180 |     });
  181 | 
  182 |     test('currency values (ر.س) display correctly', async ({ page }) => {
  183 |       await page.goto('/dashboard', { waitUntil: 'networkidle' });
  184 |       // Capture the full dashboard which includes currency displays
  185 |       await expect(page).toHaveScreenshot('rtl-currency-display.png', {
  186 |         ...SCREENSHOT_OPTS,
  187 |         fullPage: true,
  188 |         mask: dynamicMasks(page),
  189 |       });
  190 |     });
  191 |   });
  192 | });
  193 | 
```
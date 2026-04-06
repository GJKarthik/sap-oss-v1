// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * Arabic (ar) translations for SAC Web Components.
 */

export const SAC_I18N_AR: Record<string, string> = {
  // ── Chat Panel ──────────────────────────────────────────────────────
  'chat.ariaLabel': 'مساعد SAC AI للمحادثة',
  'chat.messagesAriaLabel': 'رسائل المحادثة',
  'chat.userSaid': 'قلت',
  'chat.assistantResponse': 'رد المساعد',
  'chat.responseInProgress': 'الرد قيد التقدم',
  'chat.approvalRequired': 'الموافقة مطلوبة',
  'chat.risk': '{{level}} مخاطر',
  'chat.affectedScope': 'النطاق المتأثر',
  'chat.rollbackPreview': 'معاينة التراجع',
  'chat.normalizedArguments': 'المعاملات المُعيَّرة',
  'chat.reject': 'رفض',
  'chat.working': 'جارٍ العمل…',
  'chat.planningReview': 'مراجعة إجراء التخطيط',
  'chat.replayTimeline': 'الجدول الزمني للإعادة',
  'chat.recentActivity': 'النشاط الأخير',
  'chat.workflowReplay': 'الجدول الزمني لإعادة سير العمل',
  'chat.workflowAudit': 'تدقيق سير العمل',
  'chat.sendAMessage': 'إرسال رسالة',
  'chat.typeMessage': 'اكتب رسالتك',
  'chat.pressEnter': 'اضغط Enter للإرسال',
  'chat.processingRequest': 'جارٍ معالجة الطلب',
  'chat.sendMessage': 'إرسال رسالة',
  'chat.ask': 'اسأل',
  'chat.defaultPlaceholder': 'اطرح سؤالاً عن بياناتك…',
  'chat.newResponse': 'رد جديد من المساعد',
  'chat.messageSent': 'تم إرسال الرسالة',
  'chat.processingYourRequest': 'جارٍ معالجة طلبك',
  'chat.responseComplete': 'اكتمل الرد',
  'chat.errorPrefix': 'خطأ: {{message}}',
  'chat.approved': 'تمت الموافقة على {{tool}}',
  'chat.rejected': 'تم رفض {{tool}}',
  'chat.reviewRequired': '{{title}}. المراجعة مطلوبة.',
  'chat.failedToExecute': 'فشل تنفيذ الإجراء المُراجَع',
  'chat.rejectedByUser': 'رفضه المستخدم قبل تنفيذ إجراء التخطيط',

  // ── Data Widget ─────────────────────────────────────────────────────
  'dataWidget.configureModel': 'قم بتكوين نموذج لعرض البيانات.',
  'dataWidget.waitingForLLM': 'في انتظار LLM لاختيار الأبعاد أو المقاييس…',
  'dataWidget.dateSeparator': 'إلى',
  'dataWidget.startDateFor': 'تاريخ البداية لـ {{label}}',
  'dataWidget.endDateFor': 'تاريخ النهاية لـ {{label}}',
  'dataWidget.low': 'أدنى',
  'dataWidget.high': 'أعلى',
  'dataWidget.analyticsWorkspace': 'مساحة عمل التحليلات',
  'dataWidget.contentSeparator': 'فاصل المحتوى',
  'dataWidget.generatedContent': 'محتوى مُنشأ',
  'dataWidget.filter': 'تصفية',
  'dataWidget.selectPlaceholder': 'اختر {{label}}…',
  'dataWidget.value': 'القيمة',
  'dataWidget.kpi': 'مؤشر الأداء',
  'dataWidget.awaitingData': 'في انتظار البيانات',
  'dataWidget.preview': 'معاينة',
  'dataWidget.noData': 'لا توجد بيانات',
  'dataWidget.liveDataUnavailable': 'البيانات المباشرة غير متاحة؛ عرض معاينة الربط. ({{message}})',
  'dataWidget.stateSyncFailed': 'فشلت مزامنة الحالة: {{message}}',
  'dataWidget.member': 'عضو {{index}}',
  'dataWidget.group': 'مجموعة {{group}}-{{index}}',
  'dataWidget.dimension': 'البُعد',
  'dataWidget.all': 'الكل',
  'dataWidget.rangeLabel': 'نطاق {{label}}',
  'dataWidget.from': 'من',
  'dataWidget.to': 'إلى',

  // ── Filter ──────────────────────────────────────────────────────────
  'filter.defaultLabel': 'تصفية',
  'filter.defaultPlaceholder': 'اختر...',
  'filter.selectedItems': 'تم تحديد {{count}} عناصر',
  'filter.selectedItem': 'تم تحديد {{label}}',
  'filter.itemSelected': 'تم تحديد {{label}}، {{count}} إجمالي',
  'filter.itemDeselected': 'تم إلغاء تحديد {{label}}، {{count}} إجمالي',

  // ── Slider ──────────────────────────────────────────────────────────
  'slider.defaultLabel': 'القيمة',

  // ── KPI ─────────────────────────────────────────────────────────────
  'kpi.target': 'الهدف: {{value}}',

  // ── Table ───────────────────────────────────────────────────────────
  'table.loadingData': 'جارٍ تحميل بيانات الجدول…',
  'table.noRows': 'لا توجد صفوف للعرض.',
  'table.paginationEmpty': '٠ من ٠',
  'table.paginationInfo': '{{start}}-{{end}} من {{total}}',
  'table.selectAll': 'تحديد كل الصفوف',
  'table.selectRow': 'تحديد الصف {{id}}',
  'table.previousPage': 'الصفحة السابقة',
  'table.nextPage': 'الصفحة التالية',
  'table.defaultAriaLabel': 'جدول البيانات',

  // ── Widget ──────────────────────────────────────────────────────────
  'widget.dateFrom': 'من',
  'widget.dateTo': 'إلى',
};

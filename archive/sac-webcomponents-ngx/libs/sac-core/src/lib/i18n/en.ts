// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * English (en) translations for SAC Web Components.
 */

export const SAC_I18N_EN: Record<string, string> = {
  // ── Chat Panel ──────────────────────────────────────────────────────
  'chat.ariaLabel': 'SAC AI Chat Assistant',
  'chat.messagesAriaLabel': 'Chat messages',
  'chat.userSaid': 'You said',
  'chat.assistantResponse': 'Assistant response',
  'chat.responseInProgress': 'Response in progress',
  'chat.approvalRequired': 'Approval required',
  'chat.risk': '{{level}} risk',
  'chat.affectedScope': 'Affected scope',
  'chat.rollbackPreview': 'Rollback preview',
  'chat.normalizedArguments': 'Normalized arguments',
  'chat.reject': 'Reject',
  'chat.working': 'Working…',
  'chat.planningReview': 'Planning action review',
  'chat.replayTimeline': 'Replay timeline',
  'chat.recentActivity': 'Recent activity',
  'chat.workflowReplay': 'Workflow replay timeline',
  'chat.workflowAudit': 'Workflow audit',
  'chat.sendAMessage': 'Send a message',
  'chat.typeMessage': 'Type your message',
  'chat.pressEnter': 'Press Enter to send',
  'chat.processingRequest': 'Processing request',
  'chat.sendMessage': 'Send message',
  'chat.ask': 'Ask',
  'chat.defaultPlaceholder': 'Ask a question about your data…',
  'chat.newResponse': 'New response from assistant',
  'chat.messageSent': 'Message sent',
  'chat.processingYourRequest': 'Processing your request',
  'chat.responseComplete': 'Response complete',
  'chat.errorPrefix': 'Error: {{message}}',
  'chat.approved': 'Approved {{tool}}',
  'chat.rejected': 'Rejected {{tool}}',
  'chat.reviewRequired': '{{title}}. Review required.',
  'chat.failedToExecute': 'Failed to execute the reviewed action',
  'chat.rejectedByUser': 'Rejected by user before executing planning action',

  // ── Data Widget ─────────────────────────────────────────────────────
  'dataWidget.configureModel': 'Configure a model to display data.',
  'dataWidget.waitingForLLM': 'Waiting for LLM to select dimensions or measures…',
  'dataWidget.dateSeparator': 'to',
  'dataWidget.startDateFor': 'Start date for {{label}}',
  'dataWidget.endDateFor': 'End date for {{label}}',
  'dataWidget.low': 'Low',
  'dataWidget.high': 'High',
  'dataWidget.analyticsWorkspace': 'Analytics workspace',
  'dataWidget.contentSeparator': 'Content separator',
  'dataWidget.generatedContent': 'Generated content',
  'dataWidget.filter': 'Filter',
  'dataWidget.selectPlaceholder': 'Select {{label}}…',
  'dataWidget.value': 'Value',
  'dataWidget.kpi': 'KPI',
  'dataWidget.awaitingData': 'Awaiting data',
  'dataWidget.preview': 'Preview',
  'dataWidget.noData': 'No data',
  'dataWidget.liveDataUnavailable': 'Live data unavailable; showing binding preview. ({{message}})',
  'dataWidget.stateSyncFailed': 'State sync failed: {{message}}',
  'dataWidget.member': 'Member {{index}}',
  'dataWidget.group': 'Group {{group}}-{{index}}',
  'dataWidget.dimension': 'Dimension',
  'dataWidget.all': 'All',
  'dataWidget.rangeLabel': '{{label}} range',
  'dataWidget.from': 'From',
  'dataWidget.to': 'To',

  // ── Filter ──────────────────────────────────────────────────────────
  'filter.defaultLabel': 'Filter',
  'filter.defaultPlaceholder': 'Select...',
  'filter.selectedItems': 'Selected {{count}} items',
  'filter.selectedItem': 'Selected {{label}}',
  'filter.itemSelected': '{{label}} selected, {{count}} total',
  'filter.itemDeselected': '{{label}} deselected, {{count}} total',

  // ── Slider ──────────────────────────────────────────────────────────
  'slider.defaultLabel': 'Value',

  // ── KPI ─────────────────────────────────────────────────────────────
  'kpi.target': 'Target: {{value}}',

  // ── Table ───────────────────────────────────────────────────────────
  'table.loadingData': 'Loading table data…',
  'table.noRows': 'No rows to display.',
  'table.paginationEmpty': '0 of 0',
  'table.paginationInfo': '{{start}}-{{end}} of {{total}}',
  'table.selectAll': 'Select all rows',
  'table.selectRow': 'Select row {{id}}',
  'table.previousPage': 'Previous page',
  'table.nextPage': 'Next page',
  'table.defaultAriaLabel': 'Data table',
};

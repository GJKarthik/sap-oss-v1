// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2024 SAP SE
/**
 * French (fr) translations for SAC Web Components.
 */

export const SAC_I18N_FR: Record<string, string> = {
  // ── Chat Panel ──────────────────────────────────────────────────────
  'chat.ariaLabel': 'Assistant IA SAC',
  'chat.messagesAriaLabel': 'Messages du chat',
  'chat.userSaid': 'Vous avez dit',
  'chat.assistantResponse': 'Réponse de l\'assistant',
  'chat.responseInProgress': 'Réponse en cours',
  'chat.approvalRequired': 'Approbation requise',
  'chat.risk': 'Risque {{level}}',
  'chat.affectedScope': 'Portée affectée',
  'chat.rollbackPreview': 'Aperçu de l\'annulation',
  'chat.normalizedArguments': 'Arguments normalisés',
  'chat.reject': 'Rejeter',
  'chat.working': 'En cours…',
  'chat.planningReview': 'Revue de l\'action planifiée',
  'chat.replayTimeline': 'Chronologie de relecture',
  'chat.recentActivity': 'Activité récente',
  'chat.workflowReplay': 'Chronologie de relecture du workflow',
  'chat.workflowAudit': 'Audit du workflow',
  'chat.sendAMessage': 'Envoyer un message',
  'chat.typeMessage': 'Saisissez votre message',
  'chat.pressEnter': 'Appuyez sur Entrée pour envoyer',
  'chat.processingRequest': 'Traitement de la demande',
  'chat.sendMessage': 'Envoyer le message',
  'chat.ask': 'Demander',
  'chat.defaultPlaceholder': 'Posez une question sur vos données…',
  'chat.newResponse': 'Nouvelle réponse de l\'assistant',
  'chat.messageSent': 'Message envoyé',
  'chat.processingYourRequest': 'Traitement de votre demande',
  'chat.responseComplete': 'Réponse terminée',
  'chat.errorPrefix': 'Erreur : {{message}}',
  'chat.approved': '{{tool}} approuvé',
  'chat.rejected': '{{tool}} rejeté',
  'chat.reviewRequired': '{{title}}. Vérification requise.',
  'chat.failedToExecute': 'Échec de l\'exécution de l\'action vérifiée',
  'chat.rejectedByUser': 'Rejeté par l\'utilisateur avant l\'exécution de l\'action planifiée',

  // ── Data Widget ─────────────────────────────────────────────────────
  'dataWidget.configureModel': 'Configurez un modèle pour afficher les données.',
  'dataWidget.waitingForLLM': 'En attente de la sélection des dimensions ou mesures par le LLM…',
  'dataWidget.dateSeparator': 'au',
  'dataWidget.startDateFor': 'Date de début pour {{label}}',
  'dataWidget.endDateFor': 'Date de fin pour {{label}}',
  'dataWidget.low': 'Bas',
  'dataWidget.high': 'Haut',
  'dataWidget.analyticsWorkspace': 'Espace de travail analytique',
  'dataWidget.contentSeparator': 'Séparateur de contenu',
  'dataWidget.generatedContent': 'Contenu généré',
  'dataWidget.filter': 'Filtre',
  'dataWidget.selectPlaceholder': 'Sélectionner {{label}}…',
  'dataWidget.value': 'Valeur',
  'dataWidget.kpi': 'KPI',
  'dataWidget.awaitingData': 'En attente des données',
  'dataWidget.preview': 'Aperçu',
  'dataWidget.noData': 'Aucune donnée',
  'dataWidget.liveDataUnavailable': 'Données en direct indisponibles ; aperçu de la liaison affiché. ({{message}})',
  'dataWidget.stateSyncFailed': 'Échec de la synchronisation de l\'état : {{message}}',
  'dataWidget.member': 'Membre {{index}}',
  'dataWidget.group': 'Groupe {{group}}-{{index}}',
  'dataWidget.dimension': 'Dimension',
  'dataWidget.all': 'Tous',
  'dataWidget.rangeLabel': 'Plage de {{label}}',

  // ── Filter ──────────────────────────────────────────────────────────
  'filter.defaultLabel': 'Filtre',
  'filter.defaultPlaceholder': 'Sélectionner...',
  'filter.selectedItems': '{{count}} éléments sélectionnés',
  'filter.selectedItem': '{{label}} sélectionné',
  'filter.itemSelected': '{{label}} sélectionné, {{count}} au total',
  'filter.itemDeselected': '{{label}} désélectionné, {{count}} au total',

  // ── Slider ──────────────────────────────────────────────────────────
  'slider.defaultLabel': 'Valeur',

  // ── KPI ─────────────────────────────────────────────────────────────
  'kpi.target': 'Cible : {{value}}',

  // ── Table ───────────────────────────────────────────────────────────
  'table.loadingData': 'Chargement des données du tableau…',
  'table.noRows': 'Aucune ligne à afficher.',
  'table.paginationEmpty': '0 sur 0',
  'table.paginationInfo': '{{start}}-{{end}} sur {{total}}',
};

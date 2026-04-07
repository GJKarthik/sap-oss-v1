# ============================================================
# Cross-Service Reasoning Rules
# Blanket AI Safety Governance - Service Integration
# 
# This file implements cross-service reasoning that enables
# holistic governance across all services. Safety guarantees
# propagate transitively across service boundaries.
#
# Reference: safety-ai-governance.pdf Section 7
# ============================================================

# Package declaration
package cross_service;

# ------------------------------------------------------------
# SERVICE REGISTRY
# ------------------------------------------------------------

# service(ServiceId, ServiceType, Language)
service("/nLocalModels", "inference", "mojo").
service("/nSearchService", "search", "mojo").
service("/nTimeSeries", "analytics", "mojo").
service("/nNewsService", "news", "zig").
service("/nDeductiveDatabase", "reasoning", "mojo").
service("/nPipelineService", "orchestration", "zig").
service("/nGenFoundry", "generation", "zig").
service("/nUniversalPrompt", "prompt", "zig").

# ------------------------------------------------------------
# SERVICE CAPABILITIES
# ------------------------------------------------------------

# service_provides(ServiceId, Capability)
service_provides("/nLocalModels", "text_generation").
service_provides("/nLocalModels", "embedding").
service_provides("/nLocalModels", "chat_completion").
service_provides("/nLocalModels", "function_calling").

service_provides("/nSearchService", "vector_search").
service_provides("/nSearchService", "full_text_search").
service_provides("/nSearchService", "hybrid_search").
service_provides("/nSearchService", "semantic_search").

service_provides("/nTimeSeries", "anomaly_detection").
service_provides("/nTimeSeries", "forecasting").
service_provides("/nTimeSeries", "pattern_recognition").
service_provides("/nTimeSeries", "trend_analysis").

service_provides("/nNewsService", "news_aggregation").
service_provides("/nNewsService", "gdelt_integration").
service_provides("/nNewsService", "sentiment_analysis").

service_provides("/nDeductiveDatabase", "rule_evaluation").
service_provides("/nDeductiveDatabase", "fact_query").
service_provides("/nDeductiveDatabase", "compliance_check").
service_provides("/nDeductiveDatabase", "model_selection").

service_provides("/nPipelineService", "data_orchestration").
service_provides("/nPipelineService", "workflow_execution").
service_provides("/nPipelineService", "etl_processing").

service_provides("/nGenFoundry", "code_generation").
service_provides("/nGenFoundry", "template_expansion").

service_provides("/nUniversalPrompt", "prompt_management").
service_provides("/nUniversalPrompt", "prompt_versioning").

# ------------------------------------------------------------
# SERVICE DEPENDENCIES
# ------------------------------------------------------------

# service_depends_on(ServiceId, DependsOnService, Capability)
service_depends_on("/nSearchService", "/nLocalModels", "embedding").
service_depends_on("/nTimeSeries", "/nDeductiveDatabase", "rule_evaluation").
service_depends_on("/nNewsService", "/nLocalModels", "text_generation").
service_depends_on("/nNewsService", "/nSearchService", "semantic_search").
service_depends_on("/nPipelineService", "/nDeductiveDatabase", "compliance_check").
service_depends_on("/nGenFoundry", "/nLocalModels", "text_generation").
service_depends_on("/nUniversalPrompt", "/nDeductiveDatabase", "fact_query").

# Transitive dependency
service_transitively_depends_on(S1, S2, Cap) :-
    service_depends_on(S1, S2, Cap).

service_transitively_depends_on(S1, S3, Cap) :-
    service_depends_on(S1, S2, _),
    service_transitively_depends_on(S2, S3, Cap).

# ------------------------------------------------------------
# CROSS-SERVICE SAFETY PROPAGATION
# ------------------------------------------------------------

# If a model fails safety, exclude from ALL cross-service tasks
# This is the key blanket control mechanism

# Service can use a model only if it's safe
service_can_use_model(Service, ModelId) :-
    service(Service, _, _),
    available_model(ModelId),
    safe_genai(ModelId).

# Cross-service safe model selection
cross_service_safe(Service, ModelId) :-
    service_provides(Service, Cap),
    available_for(ModelId, Cap),
    safe_genai(ModelId).

# If any upstream dependency uses an unsafe model, downstream is also unsafe
cross_service_unsafe(Service, Reason) :-
    service_depends_on(Service, UpstreamService, _),
    cross_service_unsafe(UpstreamService, UpstreamReason),
    Reason = "upstream_unsafe: " + UpstreamReason.

cross_service_unsafe(Service, Reason) :-
    service(Service, _, _),
    service_can_use_model(Service, ModelId),
    not safe_genai(ModelId),
    Reason = "unsafe_model: " + ModelId.

# Service is safe if not unsafe
cross_service_healthy(Service) :-
    service(Service, _, _),
    not cross_service_unsafe(Service, _).

# ------------------------------------------------------------
# MODEL SELECTION FOR SPECIFIC TASKS
# ------------------------------------------------------------

# Best model for variance explanation (financial use case)
best_model_for_variance_explanation(VarianceId, ModelId) :-
    variance(VarianceId, _, _, _, _),
    preferred_safe_model("variance_explanation", ModelId).

# Best model for forecasting
best_model_for_forecast(SeriesId, ModelId) :-
    timeseries(SeriesId, _, _, _),
    preferred_safe_model("forecasting", ModelId).

# Best model for news summarization
best_model_for_news(NewsId, ModelId) :-
    news_item(NewsId, _, _, _),
    preferred_safe_model("news_summarization", ModelId).

# Best model for code generation
best_model_for_code(TaskId, ModelId) :-
    code_task(TaskId, _, _),
    preferred_safe_model("code_completion", ModelId).

# Best model for embedding (vector search)
best_model_for_embedding(QueryId, ModelId) :-
    search_query(QueryId, _, _),
    preferred_safe_model("embedding", ModelId),
    has_capability(ModelId, "embedding").

# ------------------------------------------------------------
# CROSS-SERVICE REASONING: ANOMALY-NEWS CORRELATION
# ------------------------------------------------------------

# Correlate anomalies with news events within a time window
anomaly_correlated_with_news(AnomalyId, NewsId, Confidence) :-
    anomaly(AnomalyId, SeriesId, AnomalyTime, _, _),
    news_item(NewsId, _, NewsTime, _),
    news_sentiment(NewsId, Sentiment),
    fn:abs(AnomalyTime - NewsTime) < 172800,  # 48 hours
    time_proximity_score(AnomalyTime, NewsTime, TimeScore),
    sentiment_relevance(Sentiment, SeriesId, SentimentScore),
    Confidence = (TimeScore + SentimentScore) / 2.

# Time proximity score (closer = higher)
time_proximity_score(T1, T2, Score) :-
    Diff = fn:abs(T1 - T2),
    Score = 1.0 - (Diff / 172800).

# Sentiment relevance for financial series
sentiment_relevance("negative", SeriesId, 0.8) :-
    financial_series(SeriesId).

sentiment_relevance("positive", SeriesId, 0.6) :-
    financial_series(SeriesId).

sentiment_relevance("neutral", SeriesId, 0.3) :-
    financial_series(SeriesId).

# ------------------------------------------------------------
# CROSS-SERVICE REASONING: VARIANCE ANALYSIS
# ------------------------------------------------------------

# Unexplained variance (no correlated news or anomaly)
unexplained_variance(VarianceId) :-
    variance(VarianceId, _, Amount, _, _),
    fn:abs(Amount) > 10000,
    not variance_explained_by_news(VarianceId, _, _),
    not variance_explained_by_anomaly(VarianceId, _, _).

# Variance explained by news
variance_explained_by_news(VarianceId, NewsId, Confidence) :-
    variance(VarianceId, SeriesId, _, VarTime, _),
    news_item(NewsId, _, NewsTime, _),
    fn:abs(VarTime - NewsTime) < 86400,  # 24 hours
    news_sentiment(NewsId, Sentiment),
    Sentiment != "neutral",
    Confidence = 0.7.

# Variance explained by detected anomaly
variance_explained_by_anomaly(VarianceId, AnomalyId, Confidence) :-
    variance(VarianceId, SeriesId, _, VarTime, _),
    anomaly(AnomalyId, SeriesId, AnomalyTime, _, _),
    fn:abs(VarTime - AnomalyTime) < 3600,  # 1 hour
    Confidence = 0.9.

# ------------------------------------------------------------
# PROACTIVE ALERTS
# ------------------------------------------------------------

# Alert for unexplained material variance
alert_unexplained_material_variance(VarianceId, "high") :-
    unexplained_variance(VarianceId),
    variance(VarianceId, _, Amount, _, _),
    fn:abs(Amount) > 100000.

alert_unexplained_material_variance(VarianceId, "medium") :-
    unexplained_variance(VarianceId),
    variance(VarianceId, _, Amount, _, _),
    fn:abs(Amount) > 10000,
    fn:abs(Amount) =< 100000.

# Alert for correlated anomalies across series
alert_correlated_anomalies(A1, A2, Reason) :-
    anomaly(A1, S1, T1, _, _),
    anomaly(A2, S2, T2, _, _),
    S1 != S2,
    fn:abs(T1 - T2) < 3600,
    strong_positive_correlation(S1, S2, _),
    Reason = "Correlated series show simultaneous anomalies".

# Strong positive correlation between series
strong_positive_correlation(S1, S2, Correlation) :-
    series_correlation(S1, S2, Correlation),
    Correlation > 0.7.

# Alert for service health
alert_service_unhealthy(Service, Reason, "critical") :-
    cross_service_unsafe(Service, Reason).

# Alert for missing dependency
alert_dependency_unavailable(Service, Dependency, "critical") :-
    service_depends_on(Service, Dependency, _),
    not service_healthy(Dependency).

# ------------------------------------------------------------
# INFERENCE TRACKING AND AUDIT
# ------------------------------------------------------------

# Successful inference
successful_inference(ReqId, ModelId) :-
    inference_request(ReqId, ModelId, _, _),
    inference_result(ReqId, _, _, "stop").

# Failed inference
failed_inference(ReqId, ModelId, Reason) :-
    inference_request(ReqId, ModelId, _, _),
    inference_result(ReqId, _, _, Reason),
    Reason != "stop",
    Reason != "length".

# Model success rate
model_total_inferences(ModelId, Count) :-
    inference_request(_, ModelId, _, _)
    |> do fn:group_by(ModelId),
    let Count = fn:count(_).

model_successful_inferences(ModelId, Count) :-
    successful_inference(_, ModelId)
    |> do fn:group_by(ModelId),
    let Count = fn:count(_).

model_success_rate(ModelId, SuccessCount, TotalCount) :-
    model_total_inferences(ModelId, TotalCount),
    model_successful_inferences(ModelId, SuccessCount).

# Alert for low success rate
alert_low_success_rate(ModelId, Rate, "warning") :-
    model_success_rate(ModelId, Success, Total),
    Total > 100,
    Rate = Success / Total,
    Rate < 0.95.

# ------------------------------------------------------------
# PARETO-OPTIMAL MODEL SELECTION
# ------------------------------------------------------------

# Candidate models with their metrics
candidate_models(Task, ModelId, Latency, Accuracy, Cost) :-
    available_for(ModelId, Task),
    safe_genai(ModelId),
    model_metric(ModelId, "genai_latency_p95_ms", Latency),
    model_metric(ModelId, "accuracy", Accuracy),
    model_metric(ModelId, "cost_per_1k_tokens", Cost).

# Model is dominated if another model is better in all dimensions
dominated(Task, ModelId) :-
    candidate_models(Task, ModelId, L1, A1, C1),
    candidate_models(Task, OtherId, L2, A2, C2),
    ModelId != OtherId,
    L2 =< L1,
    A2 >= A1,
    C2 =< C1,
    (L2 < L1 ; A2 > A1 ; C2 < C1).

# Pareto-optimal model
pareto_optimal(Task, ModelId) :-
    candidate_models(Task, ModelId, _, _, _),
    not dominated(Task, ModelId).

# ------------------------------------------------------------
# BLANKET CONTROL INVARIANT
# ------------------------------------------------------------

# Cross-service blanket control: no unsafe model used in any service
cross_service_blanket_control_violated :-
    service(Service, _, _),
    cross_service_unsafe(Service, _).

cross_service_blanket_control_enforced :-
    not cross_service_blanket_control_violated.
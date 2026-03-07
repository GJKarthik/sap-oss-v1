# Mangle Proxy Configuration for SAP OpenAI-Compatible Server (OData Vocabularies)
# Maps OpenAI API endpoints to SAP AI Core

route("/v1/models") :- proxy_to("http://localhost:8500/v1/models"), method("GET").
route("/v1/chat/completions") :- proxy_to("http://localhost:8500/v1/chat/completions"), method("POST").
route("/v1/embeddings") :- proxy_to("http://localhost:8500/v1/embeddings"), method("POST").
route("/health") :- proxy_to("http://localhost:8500/health"), method("GET").
route("/v1/files") :- proxy_to("http://localhost:8500/v1/files"), method("GET"), method("POST").
route("/v1/moderations") :- proxy_to("http://localhost:8500/v1/moderations"), method("POST").
route("/v1/assistants") :- proxy_to("http://localhost:8500/v1/assistants"), method("GET"), method("POST").
route("/v1/threads") :- proxy_to("http://localhost:8500/v1/threads"), method("POST").
route("/v1/batches") :- proxy_to("http://localhost:8500/v1/batches"), method("GET"), method("POST").
route("/v1/hana/tables") :- proxy_to("http://localhost:8500/v1/hana/tables"), method("GET").
route("/v1/hana/vectors") :- proxy_to("http://localhost:8500/v1/hana/vectors"), method("POST").
route("/v1/hana/search") :- proxy_to("http://localhost:8500/v1/hana/search"), method("POST").

model_alias("gpt-4", "dca062058f34402b").
model_alias("claude-3.5-sonnet", "dca062058f34402b").
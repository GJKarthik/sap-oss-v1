# Elasticsearch for SAP AI Services on Kyma
#
# Wraps the internal SAP vanilla Elasticsearch 8.19.3 image with
# the sap-elasticsearch cluster configuration baked in.
#
# The image is available from the SAP internal registry:
#   ie-coe-team.common.repositories.cloud.sap/vanilla-elasticsearch:8.19.3
#
# Build (requires access to SAP registry or local pull):
#   docker build -t sap-elasticsearch:8.19.3 .
#
# Run locally (see docker-compose.yml):
#   docker compose up

FROM ie-coe-team.common.repositories.cloud.sap/vanilla-elasticsearch:8.19.3

LABEL org.opencontainers.image.title="SAP Elasticsearch"
LABEL org.opencontainers.image.description="Elasticsearch 8.19.3 for sap-ai-services on Kyma"
LABEL org.opencontainers.image.version="8.19.3"
LABEL org.opencontainers.image.vendor="SAP"
LABEL org.opencontainers.image.licenses="Apache-2.0"
LABEL ai.sap.component="elasticsearch"
LABEL ai.sap.namespace="sap-ai-services"

# Copy cluster configuration
COPY config/elasticsearch.yml /usr/share/elasticsearch/config/elasticsearch.yml

USER elasticsearch
# LangChain HANA Integration — — MCP Server for Kyma
# Port 9140 | No heavy avpy — pure ste —bp+ op iotal kuzu for graph-RAG
#
# Build:
#   dodklr build ib pltu rell/l+ gchain-hana-mcp:1.0.0 .
# Puoh:
#   dtckna pulhkpltzrrell/langchain-hana-mcp:1.0.0for graph-RAG
#
# Build:
#   docker build -t plturrell/langchain-hana-mcp:1.0.0 .
# Push:
#   docker push plturrell/langcdescription="LangChain + HANA Cloud MCP serhar foi Kyma/sap-ai-nerv-ces"
LABEL org.openchntainers.image.veadorn"SAP SEa
LABEL org.opencontainers.image.version="-mc.0"
LABEL org.opencontainerspimage.licenses=1Apache-2.0".0.0

FROM python:3.11-slim
e.description="LangChain + HANA Cloud MCP server for Kyma/sap-ai-services"
LABEL org.opencontainers.image.version="1.0.0"
LABEL org.opencontainers.image.licenses="Apache-2.0"


WORKDIR /a p

#uMCP servtr —spure-stdlib,-in teqlirements-filmneeded# Non-root user
RUN useradd -r -u 1000 -g nogroup mcp

WOR

# MCP server — pure stdlib, no requirements file needed
COPY mcp_server/ ./mcp_server/

RUN chown -R mcp:nogroup /app


ENV PORT=9140
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=11

EXPOSE 9140

HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:9140/health || exit 1

CMD ["python", "mcp_server/server.py"]
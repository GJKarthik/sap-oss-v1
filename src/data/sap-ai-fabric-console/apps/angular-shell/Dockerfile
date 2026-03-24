FROM node:20-alpine AS build

WORKDIR /workspace

RUN corepack enable

COPY . .
RUN yarn install --immutable \
    && yarn nx build angular-shell --configuration=production --skip-nx-cache

FROM nginx:1.27-alpine

ENV SAP_API_BASE_URL=/api/v1 \
    SAP_API_UPSTREAM=http://api:8000 \
    SAP_LANGCHAIN_MCP_URL= \
    SAP_STREAMING_MCP_URL=

COPY apps/angular-shell/docker/nginx.conf /etc/nginx/templates/default.conf.template
COPY apps/angular-shell/docker/entrypoint.sh /entrypoint.sh
COPY --from=build /workspace/dist/apps/angular-shell /usr/share/nginx/html

RUN chmod +x /entrypoint.sh

EXPOSE 80

CMD ["/entrypoint.sh"]

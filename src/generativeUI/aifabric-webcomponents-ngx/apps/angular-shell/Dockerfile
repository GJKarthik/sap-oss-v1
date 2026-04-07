FROM node:20-alpine AS build

WORKDIR /workspace

RUN corepack enable

COPY . .
RUN yarn install \
    && yarn nx build angular-shell --configuration=production --skip-nx-cache

FROM nginxinc/nginx-unprivileged:1.27-alpine

ENV SAP_API_BASE_URL=/api/v1 \
    SAP_API_UPSTREAM=http://api:8000 \
    SAP_ELASTICSEARCH_MCP_URL= \
    SAP_PAL_MCP_URL=

COPY apps/angular-shell/docker/nginx.conf /etc/nginx/templates/default.conf.template
COPY --chmod=755 apps/angular-shell/docker/entrypoint.sh /entrypoint.sh
COPY --chown=101:101 --from=build /workspace/dist/apps/angular-shell /usr/share/nginx/html

# Ensure the html dir is writable by the nginx user (101) for runtime-config.js injection
USER root
RUN chown -R 101:101 /usr/share/nginx/html
USER 101

EXPOSE 8080

CMD ["/entrypoint.sh"]

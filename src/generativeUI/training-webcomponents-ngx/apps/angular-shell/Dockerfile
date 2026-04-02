FROM node:20-alpine AS build
WORKDIR /app
COPY package.json yarn.lock .yarnrc.yml ./
COPY apps/angular-shell/package.json apps/angular-shell/
RUN corepack enable && yarn install --immutable
COPY . .
RUN yarn nx build angular-shell --configuration production

FROM nginx:alpine
COPY --from=build /app/dist/apps/angular-shell/browser /usr/share/nginx/html
ENV SAP_API_BASE_URL=http://training-api:8000
COPY apps/angular-shell/docker/nginx.conf /etc/nginx/templates/default.conf.template
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]

FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

COPY packages/api-server/requirements.txt ./requirements.txt
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir -r requirements.txt

COPY packages/api-server/src ./src
COPY packages/api-server/scripts ./scripts
COPY packages/api-server/docker/entrypoint.sh /entrypoint.sh
COPY packages/api-server/.env.example ./.env.example

RUN chmod +x /entrypoint.sh

EXPOSE 8000

CMD ["/entrypoint.sh"]

# Mangle Query Service Dockerfile
# Multi-stage build for SAP BTP Cloud deployment

FROM golang:1.24-alpine AS builder

# Install build dependencies
RUN apk add --no-cache git ca-certificates

WORKDIR /app

# Copy go mod files
COPY go.mod go.sum ./

# Copy vendored mangle core
COPY vendor/ ./vendor/

# Download dependencies (will use vendor for mangle)
RUN go mod download

# Copy source code
COPY . .

# Build the service
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
    -mod=vendor \
    -ldflags="-w -s" \
    -o /mangle-query-service \
    ./cmd/server

# Runtime image
FROM gcr.io/distroless/static:nonroot

# Copy binary
COPY --from=builder /mangle-query-service /mangle-query-service

# Copy rules
COPY --from=builder /app/rules /rules

# Copy ES mappings
COPY --from=builder /app/es_mappings /es_mappings

# Run as non-root
USER nonroot:nonroot

# gRPC port
EXPOSE 50051

# Health check port (optional HTTP)
EXPOSE 8080

ENTRYPOINT ["/mangle-query-service"]
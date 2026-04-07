# BDC AIPrompt Streaming - API Reference

## Overview

This document provides a comprehensive API reference for the BDC AIPrompt Streaming service. The service exposes three interface types:

1. **Binary Protocol** (Port 6650) - Wire-compatible with Apache Pulsar
2. **HTTP Admin API** (Port 8080) - RESTful administration interface
3. **WebSocket API** (Port 8080) - Browser-friendly streaming interface

---

## Authentication

All API requests (except health checks) require authentication when enabled.

### Bearer Token Authentication

```http
Authorization: Bearer <JWT_TOKEN>
```

Tokens are obtained from SAP XSUAA/IAS and must include appropriate scopes:

| Scope | Description |
|-------|-------------|
| `aiprompt.produce` | Produce messages to any topic |
| `aiprompt.consume` | Consume messages from any topic |
| `aiprompt.admin` | Full administrative access |
| `aiprompt.admin.topics` | Topic management only |
| `aiprompt.admin.subscriptions` | Subscription management only |

---

## Binary Protocol (Port 6650)

The binary protocol is fully compatible with Apache Pulsar clients. Use any Pulsar client library:

### Connection URL

```
pulsar://hostname:6650                    # Plain
pulsar+ssl://hostname:6651                # TLS
```

### Producer Example (Java)

```java
PulsarClient client = PulsarClient.builder()
    .serviceUrl("pulsar://aiprompt-broker:6650")
    .authentication(AuthenticationFactory.token("YOUR_JWT_TOKEN"))
    .build();

Producer<byte[]> producer = client.newProducer()
    .topic("persistent://ai-core/privatellm/requests")
    .create();

producer.send("Hello, AIPrompt!".getBytes());
```

### Consumer Example (Python)

```python
import pulsar

client = pulsar.Client(
    'pulsar://aiprompt-broker:6650',
    authentication=pulsar.AuthenticationToken('YOUR_JWT_TOKEN')
)

consumer = client.subscribe(
    'persistent://ai-core/privatellm/requests',
    'my-subscription'
)

while True:
    msg = consumer.receive()
    print(f"Received: {msg.data()}")
    consumer.acknowledge(msg)
```

### Consumer Example (Go)

```go
client, _ := pulsar.NewClient(pulsar.ClientOptions{
    URL:            "pulsar://aiprompt-broker:6650",
    Authentication: pulsar.NewAuthenticationToken("YOUR_JWT_TOKEN"),
})

consumer, _ := client.Subscribe(pulsar.ConsumerOptions{
    Topic:            "persistent://ai-core/privatellm/requests",
    SubscriptionName: "my-subscription",
})

for {
    msg, _ := consumer.Receive(context.Background())
    fmt.Printf("Received: %s\n", string(msg.Payload()))
    consumer.Ack(msg)
}
```

---

## HTTP Admin API (Port 8080)

RESTful API for administration and management operations.

### Base URL

```
http://hostname:8080/admin/v2
```

### Health & Metrics

#### Health Check

```http
GET /admin/v2/brokers/health
```

**Response:**
```json
{
  "status": "ok",
  "version": "1.0.0",
  "protocolVersion": 21
}
```

#### Readiness Check

```http
GET /admin/v2/brokers/ready
```

**Response:**
```json
{
  "ready": true,
  "storage": "connected",
  "topics": 42
}
```

#### Prometheus Metrics

```http
GET /metrics
```

**Response:** Prometheus text format

```
# HELP aiprompt_messages_in_total Total messages received
# TYPE aiprompt_messages_in_total counter
aiprompt_messages_in_total{topic="ai-core/privatellm/requests"} 12345

# HELP aiprompt_messages_out_total Total messages dispatched
# TYPE aiprompt_messages_out_total counter
aiprompt_messages_out_total{topic="ai-core/privatellm/requests"} 12340
```

### Cluster Management

#### List Brokers

```http
GET /admin/v2/brokers
Authorization: Bearer <token>
```

**Response:**
```json
[
  "broker-0.aiprompt.svc.cluster.local:6650",
  "broker-1.aiprompt.svc.cluster.local:6650"
]
```

#### Get Broker Info

```http
GET /admin/v2/brokers/{broker}
Authorization: Bearer <token>
```

**Response:**
```json
{
  "serviceUrl": "pulsar://broker-0:6650",
  "serviceUrlTls": "pulsar+ssl://broker-0:6651",
  "webServiceUrl": "http://broker-0:8080",
  "webServiceUrlTls": "https://broker-0:8443",
  "loadReportType": "LoadReport",
  "timestampOfLocalData": 1708123456789
}
```

### Topic Management

#### List Topics in Namespace

```http
GET /admin/v2/persistent/{tenant}/{namespace}
Authorization: Bearer <token>
```

**Example:**
```http
GET /admin/v2/persistent/ai-core/privatellm
```

**Response:**
```json
[
  "persistent://ai-core/privatellm/requests",
  "persistent://ai-core/privatellm/responses",
  "persistent://ai-core/privatellm/embeddings"
]
```

#### Create Partitioned Topic

```http
PUT /admin/v2/persistent/{tenant}/{namespace}/{topic}/partitions
Authorization: Bearer <token>
Content-Type: application/json

4
```

**Example:**
```http
PUT /admin/v2/persistent/ai-core/privatellm/my-topic/partitions
```

#### Get Topic Stats

```http
GET /admin/v2/persistent/{tenant}/{namespace}/{topic}/stats
Authorization: Bearer <token>
```

**Response:**
```json
{
  "msgRateIn": 100.5,
  "msgRateOut": 98.2,
  "msgThroughputIn": 51200.0,
  "msgThroughputOut": 50176.0,
  "averageMsgSize": 512.0,
  "storageSize": 104857600,
  "publishers": [
    {
      "producerId": 1,
      "producerName": "producer-1",
      "msgRateIn": 100.5,
      "msgThroughputIn": 51200.0,
      "averageMsgSize": 512.0
    }
  ],
  "subscriptions": {
    "my-subscription": {
      "msgRateOut": 98.2,
      "msgThroughputOut": 50176.0,
      "msgBacklog": 5,
      "consumers": [
        {
          "consumerName": "consumer-1",
          "msgRateOut": 98.2,
          "availablePermits": 1000
        }
      ]
    }
  }
}
```

#### Delete Topic

```http
DELETE /admin/v2/persistent/{tenant}/{namespace}/{topic}
Authorization: Bearer <token>
```

**Query Parameters:**
- `force` (boolean): Force deletion even with active producers/consumers
- `deleteSchema` (boolean): Also delete associated schema

### Subscription Management

#### List Subscriptions

```http
GET /admin/v2/persistent/{tenant}/{namespace}/{topic}/subscriptions
Authorization: Bearer <token>
```

**Response:**
```json
[
  "my-subscription",
  "backup-subscription"
]
```

#### Create Subscription

```http
PUT /admin/v2/persistent/{tenant}/{namespace}/{topic}/subscription/{subscription}
Authorization: Bearer <token>
```

**Query Parameters:**
- `authoritative` (boolean): Whether to skip redirect
- `replicated` (boolean): Create replicated subscription

#### Delete Subscription

```http
DELETE /admin/v2/persistent/{tenant}/{namespace}/{topic}/subscription/{subscription}
Authorization: Bearer <token>
```

#### Skip Messages

```http
POST /admin/v2/persistent/{tenant}/{namespace}/{topic}/subscription/{subscription}/skip/{numMessages}
Authorization: Bearer <token>
```

#### Seek to Position

```http
POST /admin/v2/persistent/{tenant}/{namespace}/{topic}/subscription/{subscription}/resetcursor/{timestamp}
Authorization: Bearer <token>
```

### Schema Management

#### Get Schema

```http
GET /admin/v2/schemas/{tenant}/{namespace}/{topic}/schema
Authorization: Bearer <token>
```

**Response:**
```json
{
  "type": "JSON",
  "schema": "{\"type\":\"record\",\"name\":\"LLMRequest\",\"fields\":[{\"name\":\"prompt\",\"type\":\"string\"}]}",
  "properties": {}
}
```

#### Upload Schema

```http
POST /admin/v2/schemas/{tenant}/{namespace}/{topic}/schema
Authorization: Bearer <token>
Content-Type: application/json

{
  "type": "JSON",
  "schema": "{\"type\":\"record\",\"name\":\"LLMRequest\",\"fields\":[{\"name\":\"prompt\",\"type\":\"string\"}]}",
  "properties": {}
}
```

### Namespace Management

#### List Namespaces

```http
GET /admin/v2/namespaces/{tenant}
Authorization: Bearer <token>
```

**Response:**
```json
[
  "ai-core/privatellm",
  "ai-core/search",
  "ai-core/events"
]
```

#### Create Namespace

```http
PUT /admin/v2/namespaces/{tenant}/{namespace}
Authorization: Bearer <token>
Content-Type: application/json

{
  "replication_clusters": ["standalone"],
  "retention_policies": {
    "retentionTimeInMinutes": 1440,
    "retentionSizeInMB": 1024
  }
}
```

#### Set Retention Policy

```http
POST /admin/v2/namespaces/{tenant}/{namespace}/retention
Authorization: Bearer <token>
Content-Type: application/json

{
  "retentionTimeInMinutes": 1440,
  "retentionSizeInMB": 1024
}
```

### Tenant Management

#### List Tenants

```http
GET /admin/v2/tenants
Authorization: Bearer <token>
```

**Response:**
```json
[
  "ai-core",
  "bdc",
  "public"
]
```

#### Create Tenant

```http
PUT /admin/v2/tenants/{tenant}
Authorization: Bearer <token>
Content-Type: application/json

{
  "adminRoles": ["admin"],
  "allowedClusters": ["standalone"]
}
```

---

## WebSocket API (Port 8080)

WebSocket interface for browser-based clients.

### Connection URL

```
ws://hostname:8080/ws/v2/producer/persistent/{tenant}/{namespace}/{topic}
ws://hostname:8080/ws/v2/consumer/persistent/{tenant}/{namespace}/{topic}/{subscription}
```

### Producer WebSocket

**Connect:**
```javascript
const ws = new WebSocket(
  'ws://aiprompt-broker:8080/ws/v2/producer/persistent/ai-core/privatellm/requests',
  [],
  { headers: { 'Authorization': 'Bearer YOUR_JWT_TOKEN' } }
);
```

**Send Message:**
```javascript
ws.send(JSON.stringify({
  payload: btoa('Hello, AIPrompt!'),  // Base64 encoded
  properties: { 'key': 'value' },
  key: 'optional-message-key'
}));
```

**Receive Acknowledgment:**
```javascript
ws.onmessage = (event) => {
  const response = JSON.parse(event.data);
  if (response.result === 'ok') {
    console.log('Message ID:', response.messageId);
  } else {
    console.error('Error:', response.errorMsg);
  }
};
```

### Consumer WebSocket

**Connect:**
```javascript
const ws = new WebSocket(
  'ws://aiprompt-broker:8080/ws/v2/consumer/persistent/ai-core/privatellm/requests/my-sub'
);
```

**Receive Messages:**
```javascript
ws.onmessage = (event) => {
  const msg = JSON.parse(event.data);
  const payload = atob(msg.payload);  // Base64 decode
  console.log('Received:', payload);
  console.log('Message ID:', msg.messageId);
  
  // Acknowledge
  ws.send(JSON.stringify({ messageId: msg.messageId }));
};
```

---

## Error Codes

| HTTP Code | Error | Description |
|-----------|-------|-------------|
| 400 | BadRequest | Invalid request parameters |
| 401 | AuthenticationRequired | Missing or invalid token |
| 403 | AuthorizationFailed | Insufficient permissions |
| 404 | TopicNotFound | Topic does not exist |
| 404 | SubscriptionNotFound | Subscription does not exist |
| 409 | ProducerBusy | Producer already exists |
| 409 | ConsumerBusy | Exclusive consumer already connected |
| 412 | PreconditionFailed | Topic/subscription state prevents operation |
| 500 | InternalServerError | Internal error |
| 503 | ServiceNotReady | Broker not ready |

---

## Rate Limiting

The service implements rate limiting per client:

| Operation | Default Limit |
|-----------|--------------|
| Produce | 10,000 msg/sec |
| Consume | Unlimited |
| Admin API | 100 req/sec |

Rate limits can be configured via namespace policies.

---

## Message Format

### Binary Protocol Message

```
+------------------+------------------+------------------+
| Magic (2 bytes)  | Total Size (4B)  | Cmd Size (4B)    |
+------------------+------------------+------------------+
| Command (protobuf)                                    |
+-------------------------------------------------------+
| Checksum (optional, 4B)                               |
+-------------------------------------------------------+
| Metadata Size (4B)                                    |
+-------------------------------------------------------+
| Metadata (protobuf)                                   |
+-------------------------------------------------------+
| Payload                                               |
+-------------------------------------------------------+
```

### Message Properties

Messages can include custom properties:

```json
{
  "properties": {
    "content-type": "application/json",
    "correlation-id": "req-12345",
    "trace-id": "abc123"
  }
}
```

---

## Cross-Service Integration

### Pre-defined Topics

| Topic | Service | Purpose |
|-------|---------|---------|
| `persistent://ai-core/privatellm/requests` | ai-core-privatellm | LLM inference requests |
| `persistent://ai-core/privatellm/responses` | ai-core-privatellm | LLM inference responses |
| `persistent://ai-core/search/documents` | ai-core-search | Document indexing |
| `persistent://ai-core/events/news` | ai-core-events | News articles |
| `persistent://ai-core/rag/embedding-requests` | RAG pipeline | Embedding generation |

### Arrow Flight Integration

For high-throughput, zero-copy data transfer, use Arrow Flight on port 8815:

```python
import pyarrow.flight as flight

client = flight.connect("grpc://aiprompt-broker:8815")
reader = client.do_get(flight.Ticket(b"topic:ai-core/search/documents"))
table = reader.read_all()
```

---

## SDK Examples

### Zig Client

```zig
const pulsar = @import("pulsar");

pub fn main() !void {
    var client = try pulsar.Client.init(.{
        .service_url = "pulsar://localhost:6650",
        .auth_token = "YOUR_JWT_TOKEN",
    });
    defer client.deinit();

    var producer = try client.createProducer("persistent://ai-core/privatellm/requests");
    defer producer.deinit();

    const msg_id = try producer.send(.{
        .payload = "Hello, AIPrompt!",
        .properties = &.{
            .{ "content-type", "text/plain" },
        },
    });

    std.debug.print("Sent message: {}\n", .{msg_id});
}
```

### Node.js Client

```javascript
const Pulsar = require('pulsar-client');

const client = new Pulsar.Client({
  serviceUrl: 'pulsar://aiprompt-broker:6650',
  authentication: new Pulsar.AuthenticationToken({ token: 'YOUR_JWT_TOKEN' })
});

const producer = await client.createProducer({
  topic: 'persistent://ai-core/privatellm/requests'
});

await producer.send({
  data: Buffer.from('Hello, AIPrompt!'),
  properties: { 'content-type': 'text/plain' }
});

await producer.close();
await client.close();
```

---

## Changelog

### v1.0.0 (2026-02-18)

- Initial release
- Full Pulsar binary protocol compatibility
- SAP HANA storage backend
- XSUAA/IAS authentication
- Arrow Flight integration
- Mojo SIMD processing support
# BDC Pulsar Streaming - Architecture

## System Overview

BDC Pulsar Streaming is a high-performance, Apache Pulsar-compatible messaging system optimized for the SAP Business Data Cloud (BDC) ecosystem. It replaces the traditional Apache Pulsar storage backend (BookKeeper/ZooKeeper) with a unified **SAP HANA** storage layer, while maintaining full wire compatibility with Pulsar clients.

## Key Components

### 1. Protocol Layer (Zig)
Implemented in `zig/src/protocol/`, this layer handles the binary Pulsar protocol (version 21). 
- **Frame Parsing:** Efficient binary framing using Zig's memory-safe primitives.
- **Command Handling:** Asynchronous handling of Pulsar commands (`CONNECT`, `PRODUCER`, `SUBSCRIBE`, `SEND`, `ACK`, etc.).

### 2. Broker Core (Zig)
The central orchestrator located in `zig/src/broker/`.
- **Topic Management:** In-memory tracking of active topics and their associated producers/consumers.
- **Subscription Management:** Implementation of various Pulsar subscription modes (Exclusive, Shared, Failover, Key_Shared).
- **Dispatching:** High-throughput message dispatching from storage to active consumers.

### 3. Storage Layer (Zig + SAP HANA)
Located in `zig/src/storage/` and `zig/src/hana/`.
- **Managed Ledger:** An append-only log abstraction that segments data into ledgers.
- **SAP HANA Backend:** Durable persistence of messages, cursors, and metadata.
- **Two-Phase Commit:** Distributed transactions implemented using HANA's ACID properties.

### 4. Stream Processing (Mojo)
Located in `mojo/src/`.
- **SIMD Vectorization:** High-performance message processing using AVX-512 and other SIMD instructions.
- **ML Pipelines:** Integrated support for real-time embedding generation and semantic search on streams.
- **Windowing:** Time-based and count-based windowing for real-time aggregations.

## Data Flow

### Message Production
1. Pulsar Client sends `CommandSend` over TCP.
2. Broker parses the command and validates credentials.
3. Message is appended to the `ManagedLedger`.
4. `ManagedLedger` persists the message to `AIPROMPT_MESSAGES` table in SAP HANA.
5. Broker sends `CommandSendReceipt` back to the client.

### Message Consumption
1. Pulsar Client subscribes to a topic.
2. Broker identifies the correct `ManagedCursor` from SAP HANA.
3. Broker reads messages from HANA (or in-memory cache) starting from the cursor position.
4. Messages are dispatched to the client using `CommandMessage`.
5. Client acknowledges messages, which updates the `ManagedCursor` in HANA.

## Integration with SAP BDC

The system integrates deeply with other SAP AI Suite components:
- **AI Core Events:** Provides the streaming backbone for news and alerts.
- **AI Core Search:** Real-time indexing of streaming data for RAG.
- **AI Core PrivateLLM:** On-the-fly embedding generation and inference on message streams.

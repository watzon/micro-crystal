# Product Mission

## Pitch

µCrystal is a microservice toolkit for Crystal that helps developers build fast, type-safe distributed systems. It includes a pluggable transport/codec/registry/broker stack, a macro-driven service model, and a built-in API gateway with OpenAPI, health, and metrics.

## Users

### Primary Customers

- Crystal backend developers: building services and internal platforms
- Teams adopting microservices in Crystal: seeking discovery, routing, and messaging primitives

### User Personas

**Senior Platform Engineer** (28-45 years old)
- **Role:** Platform or infrastructure engineer
- **Context:** Needs reliable service discovery, transport, and messaging building blocks
- **Pain Points:** Glue code maintenance, lack of ecosystem parity, brittle RPC
- **Goals:** Strong defaults, observability hooks, predictable performance

**Product-Focused Developer** (22-38 years old)
- **Role:** Backend application developer
- **Context:** Wants to ship features, not reimplement transports and registries
- **Pain Points:** Boilerplate, inconsistent patterns, weak error handling
- **Goals:** Simple APIs, batteries included, ergonomic macros

## The Problem

### Fragmented microservice primitives in Crystal
Ecosystem pieces exist (HTTP, WebSocket, NATS, Consul), but they are uncoordinated and inconsistent. Delivery slows as each team reinvents the same glue.

**Our Solution:** Ship cohesive interfaces and stdlib implementations with a clean public API.

### Unsafe, ad hoc request/response handling
Manual JSON handling and error paths lead to production bugs and inconsistent status codes.

**Our Solution:** Centralized message encoding/decoding with pluggable codecs and standard error mapping.

### Missing service discovery and routing ergonomics
Service addressing and multi-transport routing are hard to do right across environments.

**Our Solution:** Registries with clear bind vs advertise semantics and gateway routing DSL.

## Differentiators

### Compile-time safety with macros
Unlike ad hoc libraries, µCrystal generates handlers and clients at compile time, reducing runtime errors and boilerplate. This yields faster iteration and fewer production issues.

### Transport-agnostic streaming
Unlike single-transport frameworks, µCrystal supports WebSocket and HTTP/2 with a unified Stream abstraction. Teams can choose the right transport without changing business logic.

## Key Features

### Core features
- **Service annotations:** `@[Micro::Service]`, `@[Micro::Method]`, `@[Micro::Subscribe]`
- **Transports:** HTTP, WebSocket, HTTP/2
- **Registries:** Memory, Consul
- **Brokers:** Memory, NATS
- **Codecs:** JSON, MessagePack with negotiation
- **Gateway:** API gateway with routing DSL, OpenAPI generator and `/api/docs`, health endpoint, metrics endpoint, CORS, response transformations, aggregation routes, retries and circuit breaker; method filtering (expose/block) and route metadata for roles; response caching scaffold
- **Auth:** JWT, mTLS, RBAC middleware
- **Observability:** Prometheus-style metrics with HTTP metrics server and pool metrics; request ID propagation; tracing scaffold

### Collaboration features
- **Consistent error responses:** shared encoder and error formatter
- **Typed client generation:** compile-time stubs for services
- **Examples and docs:** runnable demos and guides

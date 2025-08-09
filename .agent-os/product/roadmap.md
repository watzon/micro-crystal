# Product Roadmap

## Phase 0: Already Completed

- [x] Core interfaces (Service, Transport, Codec, Registry, Broker, PubSub)
- [x] HTTP transport with Client/Server
- [x] WebSocket transport for streaming
- [x] HTTP/2 transport with multiplexing
- [x] JSON and MessagePack codecs with negotiation
- [x] Memory and Consul registries
- [x] Memory and NATS brokers (pub/sub)
- [x] Handler and client stub generation via macros
- [x] Standardized error handling and message encoding
- [x] HTTP::Headers standardization across layers
- [x] Security: JWT, mTLS, RBAC guards
- [x] Connection pooling with metrics and health checks

- [x] API Gateway core
  - [x] Discovery wiring via `ServiceProxy` with registry-aware client
  - [x] Routing with `RouteRegistry` (Radix), path params, method filters (allow/block)
  - [x] CORS handler, health endpoint, and Prometheus-style `/metrics`
  - [x] OpenAPI generator and `/api/docs` endpoint
  - [x] Response transformations and aggregation routes (parallel fan-out)
  - [x] Retries and circuit breaker on backend calls

## Phase 1: API gateway enhancements

**Goal:** Polish and extend gateway capabilities beyond the core
**Success Criteria:** Route generation from annotations, per-route middleware/auth, and caching

### Features
- [ ] Automatic route generation from service annotations (DSL exists; generation pending)
- [ ] Method-level middleware chains (route-level application)
- [ ] Authorization enforcement using `required_roles` (route-level)
- [ ] Rate limiting wired into handler chain
- [ ] Response caching (read path exists; write path TODO)

### Dependencies
- Schema extraction refinement for route generation

## Phase 2: Observability

**Goal:** Production-friendly monitoring and tracing
**Success Criteria:** Unified Prometheus metrics and OpenTelemetry tracing integrated

### Features
- [x] Prometheus-style metrics
- [x] HTTP metrics server and pool metrics integration
- [ ] OpenTelemetry tracing
- [ ] Structured logging

### Dependencies
- Metrics exporter finalization

## Phase 3: Kubernetes integration

**Goal:** First-class Kubernetes auto-integration for discovery, config, and ops
**Success Criteria:** Services/gateway auto-discover peers via the Kubernetes API with zero custom wiring; deployable via Helm with sensible defaults

### Features
- [ ] Kubernetes-backed registry
  - [ ] `KubernetesRegistry` implementing `Micro::Core::Registry::Base`
  - [ ] Watch `Service`/`Endpoints`/`EndpointSlice` resources for real-time updates
  - [ ] Map labels/annotations to `HTTP::Headers` metadata
  - [ ] Namespace scoping and label/field selectors
- [ ] Addressing & advertise logic
  - [ ] Pod IP vs Service DNS selection (bind vs advertise)
  - [ ] Headless service (stateful) and ClusterIP support
  - [ ] DNS SRV fallback when API access is unavailable
- [ ] Config & security
  - [ ] In-cluster config via service account (auto-mount) and CA bundle
  - [ ] Out-of-cluster via `KUBECONFIG`
  - [ ] Minimal RBAC (Role/RoleBinding) manifest for read-only discovery
- [ ] Health & probes
  - [ ] Standard health endpoint for `livenessProbe`/`readinessProbe`
  - [ ] Graceful shutdown hooks for rolling updates
- [ ] Packaging & examples
  - [ ] Helm chart(s) with values for registry choice, metrics, auth
  - [ ] End-to-end demo: multi-service + gateway on Kind/Minikube

### Dependencies
- Kubernetes API client (HTTP + watch streaming)
- TLS verification using cluster CA
- Example manifests and Helm packaging

## Phase 4: CLI & codegen

**Goal:** Developer tooling for scaffolding and generation
**Success Criteria:** `micro` CLI with new, generate, run commands

### Features
- [ ] `micro new` and project templates
- [ ] `micro generate` for services/handlers
- [ ] `micro run` for dev server

### Dependencies
- Template set and generator

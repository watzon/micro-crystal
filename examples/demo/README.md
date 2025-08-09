% Demo (µCrystal) — Real‑World Example

This is a comprehensive, real‑world example for µCrystal (micro‑crystal). It showcases service definitions, a centralized API Gateway with OpenAPI/health/metrics, inter‑service discovery, middleware, and a single‑process dev runner for an excellent developer experience (DX).

This README follows the Standard README specification. See: https://github.com/RichardLitt/standard-readme/blob/main/spec.md

## Table of Contents

- [Background](#background)
- [Install](#install)
- [Usage](#usage)
  - [Single-process dev runner](#single-process-dev-runner)
  - [Run services separately](#run-services-separately)
  - [Gateway endpoints](#gateway-endpoints)
  - [cURL examples](#curl-examples)
- [Configuration](#configuration)
- [Development](#development)
- [Maintainers](#maintainers)
- [Contributing](#contributing)
- [License](#license)

## Background

The demo defines two services and an API Gateway:

- `CatalogService` — read‑only product catalog with seeded data and public endpoints
- `OrderService` — order creation and retrieval that calls Catalog via discovery
- `APIGateway` — central entry point with REST routing, OpenAPI, health, and Prometheus metrics

To optimize DX, configuration is centralized in `src/utilities/config.cr` (via `DemoConfig`). This avoids duplicating registry and server wiring across entrypoints.

Code layout:

- `src/services/` — service classes (`catalog.cr`, `orders.cr`)
- `src/gateways/app.cr` — gateway builder/configuration
- Entry points: `src/catalog.cr`, `src/orders.cr`, `src/gateway.cr`, `src/dev.cr`

## Install

From the repository root:

```sh
cd examples/demo
shards install
```

Build all targets:

```sh
shards build dev gateway catalog orders
```

## Usage

### Single-process dev runner

Runs catalog, orders, and the gateway in one process sharing a single in‑memory registry. Best for local development.

```sh
cd examples/demo
bin/dev
```

Defaults:

- Gateway: `http://0.0.0.0:8080`
- Catalog service: `0.0.0.0:8081`
- Orders service: `0.0.0.0:8082`

### Run services separately

When running as separate processes, use a real registry like Consul. Set `CONSUL_ADDR` so all processes discover each other.

```sh
cd examples/demo

# Consul-backed registry (example)
export CONSUL_ADDR=127.0.0.1:8500

# Start each component
bin/catalog   # uses CATALOG_ADDR or defaults to 0.0.0.0:8081
bin/orders    # uses ORDERS_ADDR  or defaults to 0.0.0.0:8082
bin/gateway   # uses GATEWAY_HOST/PORT or defaults to 0.0.0.0:8080
```

Note: The in‑memory registry is process‑local; it will not work across separate binaries.

### Gateway endpoints

The gateway exposes:

- `GET /api/catalog/products` — list products
- `GET /api/catalog/products/:id` — get a product
- `POST /api/orders` — create an order
- `GET /api/orders/:id` — get an order

Built‑in endpoints:

- `GET /api/docs` — OpenAPI JSON
- `GET /health` — health check
- `GET /metrics` — Prometheus metrics

### cURL examples

Assuming gateway at `http://localhost:8080`:

List products:

```sh
curl -s http://localhost:8080/api/catalog/products | jq
```

Create an order (uses seeded product `p-1`):

```sh
curl -s -X POST http://localhost:8080/api/orders \
  -H 'Content-Type: application/json' \
  -d '{
    "items": [ { "product_id": "p-1", "quantity": 2 } ]
  }' | jq
```

Fetch an order:

```sh
curl -s http://localhost:8080/api/orders/<order_id> | jq
```

## Configuration

Environment variables:

- `CONSUL_ADDR` — if set, uses Consul registry across processes (e.g. `127.0.0.1:8500`)
- `GATEWAY_HOST` — gateway bind host (default: `0.0.0.0`)
- `GATEWAY_PORT` — gateway port (default: `8080`)
- `CATALOG_ADDR` — catalog bind address (default: `0.0.0.0:8081`)
- `ORDERS_ADDR` — orders bind address (default: `0.0.0.0:8082`)

Centralized helpers live in `src/utilities/config.cr` (`DemoConfig.registry`, `DemoConfig.shared_registry`, `DemoConfig.service_options`).

## Development

Recommended local workflow:

```sh
cd examples/demo
shards build dev
bin/dev
```

From the repository root, you can also run:

```sh
crystal spec
./bin/ameba
crystal tool format
```

## Maintainers

- Chris Watson (@watzon)

## Contributing

PRs welcome! Please match Crystal style and keep DX‑focused changes additive and well‑documented. If updating public APIs, ensure examples and docs remain consistent.

## License

MIT © Chris Watson


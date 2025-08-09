# µCrystal

[![GitHub license](https://img.shields.io/github/license/watzon/micro-crystal)](https://github.com/watzon/micro-crystal/blob/main/LICENSE)
[![Crystal Version](https://img.shields.io/badge/crystal-%3E%3D%201.12.0-brightgreen)](https://crystal-lang.org/)

A batteries-included microservice toolkit for Crystal that mirrors and improves upon Go-Micro.

µCrystal provides a composable, opinionated framework with pluggable components for building blazing fast microservices with the safety of static typing and Ruby-like syntax ergonomics.

## Table of Contents

- [µCrystal](#µcrystal)
  - [Table of Contents](#table-of-contents)
  - [Security](#security)
  - [Background](#background)
  - [Install](#install)
  - [Usage](#usage)
    - [Service Discovery \& Addressing](#service-discovery--addressing)
  - [Why µCrystal vs Lucky/Athena?](#why-µcrystal-vs-luckyathena)
  - [API](#api)
  - [Examples](#examples)
  - [Maintainers](#maintainers)
  - [Contributing](#contributing)
  - [License](#license)

## Security

µCrystal prioritizes security by default:
- mTLS support out of the box
- JWT authentication middleware
- Role-based access control
- Built-in rate limiting and circuit breakers

For security vulnerabilities, please email security@watzon.tech.

## Background

µCrystal aims to bring the excellent design patterns of Go-Micro to the Crystal ecosystem while leveraging Crystal's unique strengths:

- **First-class async**: Leverages Crystal's fibers and event loop instead of external reactors
- **Compile-time safety**: Uses macros and generics to generate stubs/clients and catch errors early
- **Ruby-like ergonomics**: Maintains the expressiveness Crystal developers love
- **C-like performance**: Achieves blazing fast execution speeds

The project follows a phased roadmap from v0.1 spike through v1.0 stable API, implementing core microservice patterns including service discovery, pub/sub messaging, observability, and authentication.

## Install

Add this to your application's `shard.yml`:

```yaml
dependencies:
  micro:
    github: watzon/micro-crystal
```

Then run:

```bash
shards install
```

## Usage

Create a simple microservice:

```crystal
require "micro"

@[Micro::Service(name: "greeter", version: "1.0.0")]
class GreeterService
  include Micro::ServiceBase

  @[Micro::Method]
  def hello(name : String) : String
    "Hello #{name}"
  end
end

# Override options if desired
options = Micro::ServiceOptions.new(
  name: "greeter",
  registry: Micro::Registries.memory,
  server_options: Micro::ServerOptions.new(address: "0.0.0.0:8081")
)

GreeterService.run(options)
```

### Service Discovery & Addressing

µCrystal supports multiple registries and a clear separation of bind vs. advertise addresses:

- In-memory registry: ideal for single-process development; process-local and not shared across binaries
- Distributed registries (e.g., Consul): use for multi-process or multi-host deployments

Programmatic setup with top-level factories:

```crystal
require "micro"

registry = if addr = ENV["CONSUL_ADDR"]?
  Micro::Registries.consul(Micro::Core::Registry::Options.new(type: "consul", addresses: [addr]))
else
  Micro::Registries.memory
end

options = Micro::ServiceOptions.new(
  name: "my-service",
  registry: registry,
  server_options: Micro::ServerOptions.new(
    address: ENV["MICRO_SERVER_ADDRESS"]? || "0.0.0.0:8080",
    advertise_address: ENV["MICRO_ADVERTISE_ADDRESS"]?
  )
)
```

This separation enables:
- Container deployments (bind to 0.0.0.0, advertise container IP)
- NAT/load balancer scenarios (advertise public endpoint)
- Multi-NIC servers (choose which interface to advertise)

For a realistic, ergonomic dev workflow, the demo includes a single-process runner that starts multiple services and a gateway sharing one in-memory registry. When splitting into separate binaries, set `CONSUL_ADDR` to switch to Consul.

## Why µCrystal vs Lucky/Athena?

Lucky and Athena are excellent web frameworks for monolithic HTTP apps (routes/controllers/views). µCrystal is different by design:

- Microservice toolkit, not your typical web framework
  - Service boundaries, discovery, and RPC between services are first-class
  - Pluggable transports (HTTP/WebSocket today; others can be added)
- Built-in discovery, routing, and gateway
  - Registries (memory, Consul) and selectors (round-robin, random)
  - API gateway: routing DSL (Radix), method filters (expose/block), CORS, response transformations, aggregation routes, retries/circuit breaker
  - OpenAPI generator (`/api/docs`), health, and Prometheus-style metrics (`/metrics`)
- Async RPC and Pub/Sub out of the box
  - Brokers (memory, NATS) for event-driven communication
  - Macro annotations for services, methods, subscriptions
- Opinionated middleware pipeline
  - Logging, timing, compression, rate limiting, JWT/mTLS, RBAC
- Observability
  - Prometheus-style metrics with HTTP metrics server
  - Connection pool metrics and request ID propagation
  - Tracing scaffold (OpenTelemetry-ready)
- DX-first with compile-time safety
  - Crystal macros generate handlers/clients and catch errors early
  - Top-level `Micro::*` factories hide low-level plumbing

If you’re building a single web app with templates and controllers, Lucky or Athena may be a better fit. If you’re composing multiple services with discovery, messaging, and a gateway, µCrystal is the right choice.

## API

High-level APIs are exposed under the `Micro` namespace; low-level internals live under `Micro::Core` and `Micro::Stdlib`.

- `Micro::ServiceBase` — service lifecycle and handler integration
- `Micro::Transports`, `Micro::Registries`, `Micro::Codecs`, `Micro::Brokers` — factories for pluggable components
- `Micro::Gateway` — API gateway builder with routing DSL, OpenAPI generator (`/api/docs`), health, metrics (`/metrics`), CORS, transformations, aggregation, and auth

Annotations for macro-driven development:
- `@[Micro::Service]` — declare a service (name, version, middleware)
- `@[Micro::Method]` — expose a method as RPC endpoint
- `@[Micro::Subscribe]` — subscribe to broker topics

## Examples

- Hello world: [examples/hello_world.cr](./examples/hello_world.cr)
- Real-world demo (multi-service + gateway): see [examples/demo/README.md](./examples/demo/README.md)

## Maintainers

- [@watzon](https://github.com/watzon) - Chris Watson <cawatson1993@gmail.com>

## Contributing

We welcome contributions! Please see our [Contributing Guidelines](CONTRIBUTING.md) (coming soon).

- Questions? Open an issue with the `question` label
- Bug reports and feature requests welcome
- PRs accepted - please discuss major changes first
- All contributors must sign off on commits

Please follow the [Crystal Code of Conduct](https://github.com/crystal-lang/crystal/blob/master/CODE_OF_CONDUCT.md).

## License

Apache-2.0 © 2025 Chris Watson

See [LICENSE](LICENSE) for details.

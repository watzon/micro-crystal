# AGENTS.md - µCrystal Development Guide

## Build/Test/Lint Commands
- **Install dependencies**: `shards install`
- **Run all tests**: `crystal spec`
- **Run single test**: `crystal spec spec/micro/core/service_spec.cr`
- **Run linter**: `./bin/ameba` (fallback: `ameba`)
- **Format code**: `crystal tool format`
- **Build targets**: `shards build` (see shard.yml for specific targets)

## Code Style Guidelines
- **Imports**: Group stdlib first, then dependencies, then local requires
- **Types**: Always use explicit types for method parameters and return values (`def method(param : String) : Bool`)
- **Naming**: Use descriptive names, functions are verbs, variables are nouns (no 1-2 char identifiers)
- **Error handling**: Prefer early returns and shallow nesting, handle errors/edge cases first
- **Comments**: Add sparingly for non-obvious logic, focus on "why" not "what"
- **Symbols**: Avoid symbols in regular code, use enums instead for type safety (symbols OK in macros)
- **No `.to_sym`**: This method doesn't exist in Crystal, use enums or string constants

## Architecture Patterns
- **Core interfaces**: `src/micro/core/` - abstract base classes and protocols
- **Default implementations**: `src/micro/stdlib/` - HTTP transport, JSON/MsgPack codecs, registries
- **Service annotations**: Use `@[Micro::Service]`, `@[Micro::Method]`, `@[Micro::Subscribe]` macros
- **Middleware**: Implement `Micro::Core::Middleware` interface, register in service options
- **Testing**: Use Crystal's built-in spec framework with WebMock for HTTP mocking
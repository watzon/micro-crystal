require "micro"
require "./services/catalog"
require "./utilities/config"

registry = DemoConfig.registry

options = DemoConfig.service_options("catalog", "CATALOG_ADDR", "0.0.0.0:8081", registry)
CatalogService.new(options).run

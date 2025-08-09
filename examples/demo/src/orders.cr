require "micro"
require "./services/orders"
require "./utilities/config"

registry = DemoConfig.registry

options = DemoConfig.service_options("orders", "ORDERS_ADDR", "0.0.0.0:8082", registry)
OrderService.new(options).run

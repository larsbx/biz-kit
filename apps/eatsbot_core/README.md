# Eatsbot Core

The core business logic module for the Eatsbot e-commerce platform, built with Elixir and the Ash Framework.

## Overview

Eatsbot Core provides the foundational resources and business logic for a headless e-commerce system designed for small businesses, particularly restaurants with delivery services. The system is built around four main domains:

### Domains

#### Products
Complete product management with support for variants, options, collections, and multi-currency pricing.

**Resources:**
- `Product` - Main product entity with SKU, description, and state management
- `Variant` - Product variations (e.g., different sizes/colors)
- `Price` - Multi-currency pricing for products and variants
- `Option` & `OptionValue` - Product customization options (Size, Color, etc.)
- `Collection` - Product grouping and categorization
- `Type` - Product type definitions with custom attributes
- `DiscountRule` - Flexible discount system (percentage, fixed, bundles)

#### Carts
Shopping cart management with automatic discount calculation and checkout flow.

**Resources:**
- `Cart` - Shopping cart with currency and status tracking
- `CartLine` - Individual cart items with quantity and notes
- Supports automatic subtotal calculation with discount rules
- Checkout integration with delivery creation

#### Deliveries
Order fulfillment with state machine-based delivery tracking.

**Resources:**
- `Delivery` - Order delivery management with state transitions
- `DeliveryStateChanges` - Audit trail of state changes
- Real-time location tracking support
- Token-based authentication for delivery tracking
- Automatic stale delivery cleanup

**States:** Init → In_Preparation → Ready_To_Pickup → In_Delivery → Delivery_Done

#### Brands
Multi-brand and franchise support with location management.

**Resources:**
- `Brand` - Top-level brand entity
- `Branch` - Physical store locations with GPS coordinates

### Key Features

- **Ash Framework Integration** - Leverages Ash for resources, actions, and policies
- **GraphQL API** - Full GraphQL support via AshGraphql
- **Multi-currency Support** - Products and variants support multiple currencies
- **Discount Engine** - Flexible discount rules (percentage, fixed, x-for-y bundles)
- **Variant Generation** - Automatic variant creation from option combinations
- **Event-Driven** - Kafka integration for event streaming
- **Authorization** - Field-level policies and actor-based authorization
- **Real-time Updates** - PubSub support for live cart and delivery updates
- **Observability** - Telemetry integration for monitoring
- **Extensible** - Plugin architecture for extending functionality

## Architecture

### Extension System

Eatsbot Core implements a behavior-based extension system that allows modular functionality:

```elixir
defmodule MyExtension do
  @behaviour EatsbotCore.Extension

  def init_extension(_config), do: :ok
  def child_spec, do: []
end
```

### Data Layer

- **PostgreSQL** via AshPostgres
- Uses UUID v7 for primary keys
- Composite Money type for currency amounts
- Transaction support for data integrity

### Authorization

- Actor-based authorization (admin, user, delivery person)
- Field-level access policies
- Bypass rules for administrative access

## Installation

Add `eatsbot_core` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:eatsbot_core, "~> 1.0"}
  ]
end
```

## Configuration

```elixir
config :eatsbot, :days_for_stale, 2  # Days before deliveries become stale

config :eatsbot_core, EatsbotCore.Repo,
  database: "tololo_db",
  username: "postgres",
  password: "postgres",
  hostname: "localhost"
```

## Usage Examples

### Creating a Product with Variants

```elixir
# Create product with options
{:ok, product} = EatsbotCore.Products.Product.create(%{
  name: "T-Shirt",
  description: "Comfortable cotton t-shirt",
  sku: "TSHIRT-001",
  state: :enabled
})

# Add size option
product = EatsbotCore.Products.Product.ensure_option_exists!(product, "Size")
size_option = EatsbotCore.Products.Product.get_or_create_option!(product, "Size")
EatsbotCore.Products.Option.add_value!(size_option, "S")
EatsbotCore.Products.Option.add_value!(size_option, "M")
EatsbotCore.Products.Option.add_value!(size_option, "L")

# Generate variants automatically
EatsbotCore.Products.Product.generate_variants!(product)
```

### Managing Shopping Carts

```elixir
# Create cart
{:ok, cart} = EatsbotCore.Carts.Cart.create(%{currency: "USD"})

# Add items
{:ok, cart} = EatsbotCore.Carts.Cart.add_variant!(cart, variant_id, quantity: 2)

# Checkout
{:ok, public_auth_key} = EatsbotCore.Carts.Cart.checkout_delivery!(
  cart_id,
  %{
    delivery_address: "123 Main St",
    customer_name: "John Doe"
  }
)
```

## Testing

```bash
mix test
```

## Documentation

Generate documentation with ExDoc:

```bash
mix docs
```

## Contributing

This is part of the Eatsbot e-commerce platform. See the main repository for contribution guidelines.

## License

AGPLv3 - See LICENSE file for details.


## Shared-tenant admission is closed

The legacy catalog/cart/order resources do not establish merchant/home ownership.
Retain isolated runtimes, stores, credentials and routing. The guarded read-only
CatalogBridge requires a reviewed isolated source binding and current host grant;
its former merchant-only `preview/2` refuses. This is candidate projection, not
a production writer cutover. See the [source audit, ownership contract and pending
persistence decisions](../../docs/architecture/2026-11-01-eatsbot-home-isolation-boundary.md).

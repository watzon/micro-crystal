module Micro
  module Stdlib
    # Provides utilities for safer nil handling patterns
    module NilSafe
      # Execute a block with a non-nil value, or return a default
      def self.with_default(value : T?, default : U, &block : T -> V) : V | U forall T, U, V
        if val = value
          yield val
        else
          default
        end
      end

      # Execute a block only if the value is non-nil
      def self.if_present(value : T?, &block : T -> _) : Nil forall T
        if val = value
          yield val
        end
        nil
      end

      # Map a value if present, otherwise return nil
      def self.map(value : T?, &block : T -> U) : U? forall T, U
        if val = value
          yield val
        else
          nil
        end
      end

      # Get value or raise with custom error
      def self.require(value : T?, message : String) : T forall T
        value || raise ArgumentError.new(message)
      end

      # Chain multiple nilable operations
      def self.chain(value : T?, &block : T -> U?) : U? forall T, U
        if val = value
          yield val
        else
          nil
        end
      end

      # Try multiple getters until one returns non-nil
      def self.first_of(*values : T?) : T? forall T
        values.find { |v| !v.nil? }
      end

      # All values must be non-nil
      def self.all_present?(*values) : Bool
        values.all? { |v| !v.nil? }
      end

      # At least one value must be non-nil
      def self.any_present?(*values) : Bool
        values.any? { |v| !v.nil? }
      end

      # Safe property accessor macro
      macro safe_getter(name, type, default = nil)
        @{{name.id}} : {{type}}?

        def {{name.id}} : {{type}}
          @{{name.id}} || {{default || "raise \"#{name.id} not initialized\""}}
        end

        def {{name.id}}? : {{type}}?
          @{{name.id}}
        end

        def {{name.id}}=(value : {{type}})
          @{{name.id}} = value
        end
      end

      # Safe lazy initialization macro
      macro lazy_getter(name, type, &block)
        @{{name.id}} : {{type}}?

        def {{name.id}} : {{type}}
          @{{name.id}} ||= begin
            {{block.body}}
          end
        end

        def {{name.id}}? : {{type}}?
          @{{name.id}}
        end
      end
    end

    # Extension methods for nilable types
    struct Nil
      # Provide a default value for nil
      def or(default : T) : T forall T
        default
      end

      # Execute a block if nil
      def if_nil(&block)
        yield
      end

      # No-op for nil
      def if_present(&block)
        nil
      end
    end
  end
end

# Extend Object with nil-safe methods
class Object
  # Provide self as the value (no-op for non-nil)
  def or(default)
    self
  end

  # No-op for non-nil
  def if_nil(&block)
    self
  end

  # Execute block with self
  def if_present(&block)
    yield self
  end

  # Safe navigation operator equivalent
  def try(&block : self -> _)
    yield self
  rescue
    nil
  end
end

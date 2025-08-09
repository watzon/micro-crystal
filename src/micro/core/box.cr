module Micro::Core
  # Abstract base class for Box to allow untyped storage
  abstract class Box
    # Get the actual type of the stored value
    abstract def value_type : String
  end

  # Generic Box for storing typed values
  class TypedBox(T) < Box
    getter value : T

    def initialize(@value : T)
    end

    # Try to cast the value to the given type
    def cast?(target_type : U.class) : U? forall U
      @value.as?(U)
    end

    # Cast the value to the given type, raising if it fails
    def cast(target_type : U.class) : U forall U
      cast?(U) || raise "Type mismatch: expected #{target_type}, got #{@value.class}"
    end

    # Get the actual type of the stored value
    def value_type : String
      @value.class.name
    end
  end

  # Convenience method to create a Box
  def self.box(value : T) : Box forall T
    TypedBox.new(value)
  end
end

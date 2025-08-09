module Micro::Core
  # Standardized module for resources that can be closed/shutdown
  # Provides thread-safe close operations and lifecycle tracking
  module ClosableResource
    # Track whether resource is closed
    @closed = false
    @close_mutex = Mutex.new

    # Check if resource is closed (thread-safe)
    def closed? : Bool
      @close_mutex.synchronize { @closed }
    end

    # Close the resource (thread-safe, idempotent)
    def close : Nil
      @close_mutex.synchronize do
        return if @closed
        @closed = true
        perform_close
      end
    rescue ex
      Log.error(exception: ex) { "Error during close: #{self.class}" }
    end

    # Subclasses implement actual cleanup logic
    abstract def perform_close : Nil

    # Helper to ensure block executes before closing
    def ensure_closed(&)
      yield
    ensure
      close
    end

    # Check if closed and raise if true
    protected def check_closed!
      raise TransportError.new("Resource is closed", ErrorCode::ConnectionReset) if closed?
    end
  end
end

require "log"

module Micro::Core
  # Tracks spawned fibers for lifecycle management and graceful shutdown
  module FiberTracker
    Log = ::Log.for("micro.fiber_tracker")

    # Represents a tracked fiber with metadata
    class TrackedFiber
      getter name : String
      getter fiber : Fiber
      getter started_at : Time
      property finished_at : Time?
      property error : Exception?

      def initialize(@name : String, @fiber : Fiber)
        @started_at = Time.utc
      end

      def running? : Bool
        !@fiber.dead?
      end

      def duration : Time::Span?
        if finished = @finished_at
          finished - @started_at
        elsif running?
          Time.utc - @started_at
        else
          nil
        end
      end
    end

    @tracked_fibers = [] of TrackedFiber
    @fiber_mutex = Mutex.new
    @shutdown_channel : Channel(Nil)?

    # Spawn and track a fiber with automatic error handling
    def track_fiber(name : String, &block) : Fiber
      fiber = spawn do
        begin
          Log.debug { "Starting fiber: #{name}" }
          block.call
          Log.debug { "Fiber completed: #{name}" }
        rescue ex
          Log.error(exception: ex) { "Fiber crashed: #{name}" }
          mark_fiber_error(name, ex)
          raise ex # Re-raise for proper handling
        ensure
          mark_fiber_finished(name)
        end
      end

      @fiber_mutex.synchronize do
        @tracked_fibers << TrackedFiber.new(name, fiber)
      end

      fiber
    end

    # Get all tracked fibers
    def tracked_fibers : Array(TrackedFiber)
      @fiber_mutex.synchronize { @tracked_fibers.dup }
    end

    # Get running fibers
    def running_fibers : Array(TrackedFiber)
      tracked_fibers.select(&.running?)
    end

    # Wait for all fibers to complete with timeout
    def wait_all(timeout : Time::Span = 30.seconds) : Bool
      deadline = Time.monotonic + timeout

      loop do
        running = running_fibers
        return true if running.empty?

        remaining = deadline - Time.monotonic
        return false if remaining <= Time::Span.zero

        # Sleep briefly to avoid busy waiting
        sleep [remaining, 100.milliseconds].min
      end
    end

    # Shutdown all tracked fibers gracefully
    def shutdown_fibers(timeout : Time::Span = 10.seconds) : Nil
      running = running_fibers
      Log.info { "Shutting down #{running.size} fibers" }

      # If no fibers are running, return immediately
      if running.empty?
        Log.info { "All fibers already shut down" }
        return
      end

      # Create shutdown channel if needed
      @shutdown_channel ||= Channel(Nil).new

      # Send shutdown signal
      @shutdown_channel.try(&.send(nil)) rescue nil

      # Wait for fibers to finish
      if wait_all(timeout)
        Log.info { "All fibers shut down gracefully" }
      else
        running = running_fibers
        Log.warn { "#{running.size} fibers still running after timeout: #{running.map(&.name).join(", ")}" }
        running.each do |fiber|
          Log.warn { "  Fiber '#{fiber.name}' started at #{fiber.started_at}, running for #{fiber.duration}" }
        end
      end
    end

    # Get shutdown channel for cooperative shutdown
    protected def shutdown_channel : Channel(Nil)
      @shutdown_channel ||= Channel(Nil).new
    end

    # Mark fiber as finished
    private def mark_fiber_finished(name : String) : Nil
      @fiber_mutex.synchronize do
        if fiber = @tracked_fibers.find { |f| f.name == name }
          fiber.finished_at = Time.utc
        end
      end
    end

    # Mark fiber as errored
    private def mark_fiber_error(name : String, error : Exception) : Nil
      @fiber_mutex.synchronize do
        if fiber = @tracked_fibers.find { |f| f.name == name }
          fiber.error = error
        end
      end
    end

    # Create a select branch for shutdown handling
    macro when_shutdown(&block)
      when shutdown_channel.receive?
        {{ block.body }}
    end
  end
end

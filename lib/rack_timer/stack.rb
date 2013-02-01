module ActionController
  class MiddlewareStack < Array

    # this class will wrap around each Rack-based middleware and take timing snapshots of how long
    # each middleware takes to execute
    class RackTimer

      # modify this environment variable to see more or less output
      LogThreshold = ENV.has_key?('RACK_TIMER_LOG_THRESHOLD') ? ENV['RACK_TIMER_LOG_THRESHOLD'].to_f : 1.0 # millisecond

      def initialize(app)
        @app = app
      end

      def call(env)
        # Set the first middleware to be called and init a total_time
        env["MIDDLEWARE_TOTAL"] = [@app.class.to_s, 0] if !env["MIDDLEWARE_TOTAL"]

        env, incoming_elapsed_time = incoming_timestamp(env)
        status, headers, body = @app.call env

        # Determine if we are at the application yet
        application_middleware = @app.class.to_s == env["MIDDLEWARE_TIMESTAMP"][0] ? true : false

        env, outgoing_elapsed_time = outgoing_timestamp(env)

        # Set our times
        incoming_elapsed_time, outgoing_elapsed_time = incoming_elapsed_time.to_f, outgoing_elapsed_time.to_f
        total_time = incoming_elapsed_time + outgoing_elapsed_time

        # Do not add the time for the application, just the middleware layers above it
        env["MIDDLEWARE_TOTAL"][1] += total_time unless application_middleware

        # Log if it's past our threshold
        if total_time > LogThreshold
          Rails.logger.info "[Rack Timer] #{@app.class.to_s.rjust(60)} : #{("%.3f" % total_time).rjust(10)} ms (#{"%.3f" % incoming_elapsed_time} + #{"%.3f" % outgoing_elapsed_time}; #{"%.3f" % env["MIDDLEWARE_TOTAL"][1]})"
        end
        [status, headers, body]
      end

      def incoming_timestamp(env)
        elapsed_time = nil
        if env.has_key?("MIDDLEWARE_TIMESTAMP") # skip over the first middleware
          elapsed_time = (Time.now.to_f - env["MIDDLEWARE_TIMESTAMP"][1].to_f) * 1000 
        elsif env.has_key?("HTTP_X_REQUEST_START") or env.has_key?("HTTP_X_QUEUE_START")
          # if we are tracking request queuing time via New Relic's suggested header(s),
          # then lets see how much time was spent in the request queue by taking the difference
          # between Time.now from the start of the first piece of middleware
          # prefer HTTP_X_QUEUE_START over HTTP_X_REQUEST_START in case both exist
          queue_start_time = (env["HTTP_X_QUEUE_START"] || env["HTTP_X_REQUEST_START"]).gsub("t=", "").to_i
        end
        env["MIDDLEWARE_TIMESTAMP"] = [@app.class.to_s, Time.now]
        [env, elapsed_time]
      end

      def outgoing_timestamp(env)
        elapsed_time = nil
        if env.has_key?("MIDDLEWARE_TIMESTAMP")
          elapsed_time = (Time.now.to_f - env["MIDDLEWARE_TIMESTAMP"][1].to_f) * 1000
        end
        env["MIDDLEWARE_TIMESTAMP"] = [nil, Time.now]
        [env, elapsed_time]
      end
    end

    class Middleware

      # overriding the built-in Middleware.build and adding a RackTimer wrapper class
      def build(app)
        if block
          RackTimer.new klass.new(app, *build_args, &block)
        else
          RackTimer.new klass.new(app, *build_args)
        end
      end

    end

    # overriding this in order to wrap the incoming app in a RackTimer, which gives us timing on the final
    # piece of Middleware, which for Rails is the routing plus the actual Application action
    def build(app)
      active.reverse.inject(RackTimer.new(app)) { |a, e| e.build(a) }
    end
  end
end
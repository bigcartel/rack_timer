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
        # Determine if this is our first middlewarefirst_middleware = false
        if !env["MIDDLEWARE_TIME_HASH"]
          env["MIDDLEWARE_TIME_HASH"] = {}
          first_middleware = true
        end

        env = incoming_timestamp(env)
        status, headers, body = @app.call env
        env = outgoing_timestamp(env)

        # If it's our first middleware, run the report
        report(env["MIDDLEWARE_TIME_HASH"]) if first_middleware

        [status, headers, body]
      end

      def incoming_timestamp(env)
        elapsed_time = nil
        if env.has_key?("MIDDLEWARE_TIMESTAMP") # skip over the first middleware
          elapsed_time = (Time.now.to_f - env["MIDDLEWARE_TIMESTAMP"][1].to_f) * 1000 
          env["MIDDLEWARE_TIME_HASH"][env["MIDDLEWARE_TIMESTAMP"][0]] = [elapsed_time.to_f]
        elsif env.has_key?("HTTP_X_REQUEST_START") or env.has_key?("HTTP_X_QUEUE_START")
          # if we are tracking request queuing time via New Relic's suggested header(s),
          # then lets see how much time was spent in the request queue by taking the difference
          # between Time.now from the start of the first piece of middleware
          # prefer HTTP_X_QUEUE_START over HTTP_X_REQUEST_START in case both exist
          queue_start_time = (env["HTTP_X_QUEUE_START"] || env["HTTP_X_REQUEST_START"]).gsub("t=", "").to_i
#          Rails.logger.info "Rack Timer -- Queuing time: #{(Time.now.to_f * 1000000).to_i - queue_start_time} microseconds"
        end
        env["MIDDLEWARE_TIMESTAMP"] = [@app.class.to_s, Time.now]
        env
      end

      def outgoing_timestamp(env)
        elapsed_time = nil
        if env.has_key?("MIDDLEWARE_TIMESTAMP")
          elapsed_time = (Time.now.to_f - env["MIDDLEWARE_TIMESTAMP"][1].to_f) * 1000
          if env["MIDDLEWARE_TIMESTAMP"][0] and env["MIDDLEWARE_TIMESTAMP"][0] == @app.class.to_s
            # this is the actual elapsed time of the final piece of Middleware (typically routing) AND the actual
            # application's action
            env["MIDDLEWARE_TIME_HASH"]["Application"] = [elapsed_time.to_f]
          else
            env["MIDDLEWARE_TIME_HASH"][@app.class.to_s] << elapsed_time.to_f
          end
        end
        env["MIDDLEWARE_TIMESTAMP"] = [nil, Time.now]
        env
      end

      def report(hash)
        hash.each_pair do |middleware, times|
          Rails.logger.info "[Rack Timer] #{middleware.rjust(56)} #{("%.3f" % times.sum).rjust(10)} ms (#{times.map { |t| "%.3f" % t }.join(" + ")})" if times.sum > LogThreshold
        end
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
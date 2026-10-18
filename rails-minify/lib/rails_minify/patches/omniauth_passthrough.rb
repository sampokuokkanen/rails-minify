# frozen_string_literal: true

module RailsMinify
  module Patches
    # Every OmniAuth strategy is a middleware that, on every request, dups
    # itself (and its Hashie::Mash options) before looking at the path: on
    # Japan Voyage (japanvoyage.jp) about 35k allocations per pass over its
    # pages, none of them on a login path. Requests that can't be OmniAuth's
    # go straight to the app; anything that might be (or that the strategy
    # decides at runtime: callable paths, other_phase, overridden path
    # methods, test mode, a missing session, which OmniAuth reports) runs
    # OmniAuth as before.
    module OmniAuthPassthrough
      # What decides whether a request is the strategy's. A strategy that
      # overrides any of these decides for itself: always run it.
      PATH_METHODS = %i[call! on_auth_path? on_request_path? on_callback_path? on_path? request_path
                        callback_path current_path path_prefix script_name].freeze

      def self.install!
        OmniAuth::Strategy.prepend(self) unless OmniAuth::Strategy < self
      end

      # Per strategy class: are all of PATH_METHODS OmniAuth's own?
      def self.standard_paths?(klass)
        @standard ||= {}.compare_by_identity
        @standard.fetch(klass) do
          @standard[klass] = PATH_METHODS.all? { |name| [OmniAuth::Strategy, self].include?(klass.instance_method(name).owner) }
        end
      end

      def call(env)
        return super unless passthrough?(env)

        @app.call(env)
      end

      private

      def passthrough?(env)
        return false if OmniAuth.config.test_mode || !env["rack.session"] || respond_to?(:other_phase)
        return false unless OmniAuthPassthrough.standard_paths?(self.class)

        request_path = options[:request_path]
        callback_path = options[:callback_path]
        return false if request_path.respond_to?(:call) || callback_path.respond_to?(:call)

        path_info = env["PATH_INFO"].to_s.downcase
        full_path = "#{env["SCRIPT_NAME"]}#{path_info}".downcase
        prefixes = [options[:path_prefix] || OmniAuth.config.path_prefix, request_path, callback_path]
        prefixes.none? { |prefix| prefix.is_a?(String) && (path_info.start_with?(prefix.downcase) || full_path.start_with?(prefix.downcase)) }
      end
    end
  end
end

# frozen_string_literal: true

module RailsMinify
  module Patches
    # ActionDispatch::Request#host runs a regexp substitution on every call,
    # allocating a String and a MatchData even when the host has no port
    # (behind a proxy, the usual case), and Rails reads it several times per
    # request: url_options, routes constrained by host, cookies, redirects.
    #
    # The same change as rails/rails#59104 (Rails 8.2) for earlier versions:
    # no substitution without a colon, and the host kept for as long as the
    # raw host is the same String (the env's HTTP_HOST; a test's host= or
    # X-Forwarded-Host make a new one, so nothing goes stale).
    module RequestHost
      PORT = /:\d+$/

      def self.install!
        return if ActionPack.gem_version >= Gem::Version.new("8.2.0.alpha") # upstream already

        ActionDispatch::Request.prepend(self) unless ActionDispatch::Request < self
      end

      def host
        raw = raw_host_with_port
        return @__rm_host if @__rm_host_raw.equal?(raw)

        @__rm_host_raw = raw
        @__rm_host = raw.include?(":") ? raw.sub(PORT, "") : raw
      end
    end
  end
end

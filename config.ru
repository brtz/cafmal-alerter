# this code goes in your config.ru
require 'sidekiq'

Sidekiq.configure_client do |config|
  redis_db = ENV["CAFMAL-ALERTER_CACHE_DB"] || 0
  redis_port = ENV["CAFMAL-ALERTER_CACHE_PORT"] || 6379

  config.redis = {
    host: "redis" || ENV["CAFMAL-ALERTER_CACHE_HOST"],
    port: redis_port.to_i,
    db: redis_db.to_i,
    password: "foobar" || ENV["CAFMAL-ALERTER_CACHE_PASSWORD"],
    namespace: "alerter"
  }
end

require 'sidekiq/web'
map '/sidekiq' do
  use Rack::Auth::Basic, "Protected Area" do |username, password|
    # Protect against timing attacks: (https://codahale.com/a-lesson-in-timing-attacks/)
    # - Use & (do not use &&) so that it doesn't short circuit.
    # - Use digests to stop length information leaking
    Rack::Utils.secure_compare(::Digest::SHA256.hexdigest(username), ::Digest::SHA256.hexdigest(ENV["SIDEKIQ_USERNAME"])) &
      Rack::Utils.secure_compare(::Digest::SHA256.hexdigest(password), ::Digest::SHA256.hexdigest(ENV["SIDEKIQ_PASSWORD"]))
  end

  run Sidekiq::Web
end

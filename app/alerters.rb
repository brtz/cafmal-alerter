require 'sidekiq'
require 'sidekiq-cron'
require 'sidekiq-limit_fetch'
require 'cafmal'
require 'json'

# check required envs
missing_env_vars = []
missing_env_vars.push('CAFMAL_API_URL') if ENV['CAFMAL_API_URL'].nil?
missing_env_vars.push('CAFMAL_ALERTER_UUID') if ENV['CAFMAL_ALERTER_UUID'].nil?
missing_env_vars.push('CAFMAL_ALERTER_TEAM_ID') if ENV['CAFMAL_ALERTER_TEAM_ID'].nil?
missing_env_vars.push('CAFMAL_ALERTER_EMAIL') if ENV['CAFMAL_ALERTER_EMAIL'].nil?
missing_env_vars.push('CAFMAL_ALERTER_PASSWORD') if ENV['CAFMAL_ALERTER_PASSWORD'].nil?
abort "Missing required env vars! (#{missing_env_vars.join(',')})" if missing_env_vars.length > 0

Sidekiq.configure_server do |config|
  config.redis = {
    host: "redis" || ENV['CAFMAL_ALERTER_CACHE_HOST'],
    port: 6379 || ENV['CAFMAL_ALERTER_CACHE_PORT'].to_i,
    db: 0 || ENV['CAFMAL_ALERTER_CACHE_DB'].to_i,
    password: "foobar" || ENV['CAFMAL_ALERTER_CACHE_PASSWORD'],
    namespace: "alerter"
  }
end

class CafmalAlerter
  include Sidekiq::Worker

  def perform(*args)
    api_url = args[0]['api_url']
    uuid = args[0]['uuid']
    team_id = args[0]['team_id'].to_i
    email = args[0]['email']
    password = args[0]['password']

    alerts_to_run = []

    auth = Cafmal::Auth.new(api_url)
    auth.login(email, password)

    # register alerter (update if already registered)
    existing_alerter_id = nil
    alerter = Cafmal::Alerter.new(api_url, auth.token)
    alerters = JSON.parse(alerter.list.body)
    alerters.each do |found_alerter|
      if found_alerter['uuid'] == uuid
        existing_alerter_id = found_alerter['id']
        break;
      end
    end

    params_to_w = {}
    params_to_w['uuid'] = uuid
    params_to_w['heartbeat_received_at'] = DateTime.now.new_offset(0)
    if existing_alerter_id.nil?
      create_alerter_response = alerter.create(params_to_w)
    else
      params_to_w['id'] = existing_alerter_id
      create_alerter_response = alerter.update(params_to_w)
    end
    logger.info "Registered alerter (#{uuid}, team: #{team_id}): #{JSON.parse(create_alerter_response.body)['id']}"

    # get all the alerts
    alert = Cafmal::Alert.new(api_url, auth.token)
    alerts = JSON.parse(alert.list.body)

    # filter
    alerts.each do |alert|
      next if alert['team_id'] != team_id
      next unless alert['deleted_at'].nil?
      next unless alert['is_enabled']
      next if alert['is_silenced']
      next if DateTime.parse(alert['updated_at']) + Rational(alert['cooldown'], 86400) >= DateTime.now.new_offset(0)

      alerts_to_run.push(alert)
    end

    logger.info "Alerts to run:"
    logger.info alerts_to_run.to_json

    alerts_to_run.each do |alert|
      logger.info "Going to run alert: #{alert['minimum_severity']} #{alert['pattern']} #{alert['alert_method']} #{alert['alert_target']} from team: #{alert['team_id']}"
      params = alert
      matched_events = []
      severity_level = 0

      case alert['minimum_severity']
      when 'warning'
        severity_level = 1
      when 'critical'
        severity_level = 2
      when 'error'
        severity_level = 3
      end

      # get all events since alert's last successful execution
      timespan_length = ((DateTime.now.new_offset(0) - DateTime.parse(alert['updated_at'])) * 24 * 60 * 60).to_i
      event = Cafmal::Event.new(api_url, auth.token)
      events = JSON.parse(event.list(timespan_length, timespan_length))

      events.each do |event|
        event_severity = 0
        case event['severity']
        when 'warning'
          event_severity = 1
        when 'critical'
          event_severity = 2
        when 'error'
          event_severity = 3
        end

        next unless event_severity >= severity_level
        next unless event['kind'] == 'check'
        next unless event['team_id'] == team_id
        next unless File.fnmatch?(alert['pattern'], event['name'])

        matched_events.push(event)
      end
      subject = "New Cafmal Alerts (#{matched_events.length})"
      body = ''
      matched_events.each_with_index do |event,index|
        body = body + "
Event ##{index} #{event['name']}:
#{event['message']}
---------------------------------
        "
      end
      puts subject
      puts body

    end

  end

  def constantize(camel_cased_word)
    unless /\A(?:::)?([A-Z]\w*(?:::[A-Z]\w*)*)\z/ =~ camel_cased_word
      raise NameError, "#{camel_cased_word.inspect} is not a valid constant name!"
    end

    Object.module_eval("::#{$1}", __FILE__, __LINE__)
  end

end

Sidekiq::Cron::Job.create(
  name: "cafmalAlerter-#{ENV['CAFMAL_ALERTER_UUID']}",
  cron: '*/30 * * * * *',
  class: 'CafmalAlerter',
  queue: "cafmalQueue-alerter-#{ENV['CAFMAL_ALERTER_TEAM_ID']}",
  args: {
    api_url: ENV['CAFMAL_API_URL'],
    uuid: ENV['CAFMAL_ALERTER_UUID'],
    team_id: ENV['CAFMAL_ALERTER_TEAM_ID'],
    email: ENV['CAFMAL_ALERTER_EMAIL'],
    password: ENV['CAFMAL_ALERTER_PASSWORD']
  }
)

Sidekiq::Queue["cafmalQueue-#{ENV['CAFMAL_ALERTER_TEAM_ID']}"].limit = 1

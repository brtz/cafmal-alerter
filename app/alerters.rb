require 'cafmal'
require 'json'
require 'logger'

# check required envs
missing_env_vars = []
missing_env_vars.push('CAFMAL_API_URL') if ENV['CAFMAL_API_URL'].nil?
missing_env_vars.push('CAFMAL_ALERTER_UUID') if ENV['CAFMAL_ALERTER_UUID'].nil?
missing_env_vars.push('CAFMAL_ALERTER_TEAM_ID') if ENV['CAFMAL_ALERTER_TEAM_ID'].nil?
missing_env_vars.push('CAFMAL_ALERTER_EMAIL') if ENV['CAFMAL_ALERTER_EMAIL'].nil?
missing_env_vars.push('CAFMAL_ALERTER_PASSWORD') if ENV['CAFMAL_ALERTER_PASSWORD'].nil?
abort "Missing required env vars! (#{missing_env_vars.join(',')})" if missing_env_vars.length > 0


class CafmalAlerter
  require './app/alert_webhook'

  @logger = nil

  def initialize(logger)
    @logger = logger
  end

  def perform(api_url, uuid, team_id, email, password)
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

    params_to_a = {}
    params_to_a['uuid'] = uuid
    params_to_a['heartbeat_received_at'] = DateTime.now.new_offset(0)
    if existing_alerter_id.nil?
      create_alerter_response = alerter.create(params_to_a)
    else
      params_to_a['id'] = existing_alerter_id
      create_alerter_response = alerter.update(params_to_a)
    end
    @logger.info "Registered alerter (#{uuid}, team: #{team_id}): #{JSON.parse(create_alerter_response.body)['id']}"

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

    @logger.info "Alerts to run:"
    @logger.info alerts_to_run.to_json

    alerts_to_run.each do |alert|
      @logger.info "Going to run alert: #{alert['minimum_severity']} #{alert['pattern']} #{alert['alert_method']} #{alert['alert_target']} from team: #{alert['team_id']}"
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
      events = JSON.parse(event.list(timespan_length, timespan_length).body)

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

      if matched_events.length > 0
        begin
          @logger.info 'found matching events, going to alert'
          alert_to_perform = constantize('Alert' + alert['alert_method'].capitalize).new(
              matched_events,
              'FROMTOBEIMPLEMENTED',
              alert['alert_target']
          )
          result = alert_to_perform.send

          @logger.info result

          event = Cafmal::Event.new(api_url, auth.token)
          params_to_e = {}
          params_to_e['team_id'] = alert['team_id']
          params_to_e['name'] = alert['alert_method'] + '.' + alert['alert_target']
          params_to_e['message'] = result
          params_to_e['kind'] = 'alert'
          params_to_e['severity'] = alert['minimum_severity']

          create_event_response = event.create(params_to_e).body
          @logger.info "Created new event: #{JSON.parse(create_event_response)['id']}"
        rescue Exception => e
          @logger.error "Alert failed! #{alert} | #{e.inspect}"
          event = Cafmal::Event.new(api_url, auth.token)
          params_to_e = {}
          params_to_e['team_id'] = alert['team_id']
          params_to_e['name'] = 'alert_failed'
          params_to_e['message'] = "Alert #{alert['alert_method']}.#{alert['alert_target']} failed: #{e.inspect}"
          params_to_e['kind'] = 'alert'
          params_to_e['severity'] = 'error'

          create_event_response = event.create(params_to_e).body
          @logger.info "Created new event: #{JSON.parse(create_event_response)['id']}"
        end
      else
        @logger.info 'No events matching this alerter'
      end

      # update the alert
      alert_res = Cafmal::Alert.new(api_url, auth.token)
      params['updated_at'] = DateTime.now.new_offset(0)
      alert_res.update(params)
    end
  end

  def constantize(camel_cased_word)
    unless /\A(?:::)?([A-Z]\w*(?:::[A-Z]\w*)*)\z/ =~ camel_cased_word
      raise NameError, "#{camel_cased_word.inspect} is not a valid constant name!"
    end

    Object.module_eval("::#{$1}", __FILE__, __LINE__)
  end

end

logger = Logger.new(STDOUT)
alerter = CafmalAlerter.new(logger)
loop do
  alerter.perform(
      ENV['CAFMAL_API_URL'],
      ENV['CAFMAL_ALERTER_UUID'],
      ENV['CAFMAL_ALERTER_TEAM_ID'].to_i,
      ENV['CAFMAL_ALERTER_EMAIL'],
      ENV['CAFMAL_ALERTER_PASSWORD']
  )
  logger.info 'Sleeping for 30s'
  STDOUT.flush
  sleep(30)
end
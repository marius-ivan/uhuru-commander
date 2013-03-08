
module Uhuru::Ucc

  class Monit

    BOSH_APP = BOSH_APP_USER = BOSH_APP_GROUP = "vcap"

    def base_dir
      $config[:bosh][:base_dir]
    end

    def monit_dir
      File.join(base_dir, 'monit')
    end

    def monit_user_file
      File.join(monit_dir, 'monit.user')
    end

    def monit_credentials
      entry = File.read(monit_user_file).lines.find { |line| line.match(/\A#{BOSH_APP_GROUP}/) }
      user, cred = entry.split(/:/)
      [user, cred.strip]
    end

    def logger
      $config[:logger]
    end

    def monit_api_client
      user, cred = monit_credentials
      MonitApi::Client.new("http://#{user}:#{cred}@127.0.0.1:2822", :logger => logger)
    end

    def monit_bin
      File.join(base_dir, 'bosh', 'bin', 'monit')
    end

    def monitrc
      File.join(base_dir, 'bosh', 'etc', 'monitrc')
    end

    def retry_monit_request(attempts=10)
      # HACK: Monit becomes unresponsive after reload
      begin
        yield monit_api_client if block_given?
      rescue Errno::ECONNREFUSED, TimeoutError
        sleep 1
        logger.info("Monit Service Connection Refused: retrying")
        retry if (attempts -= 1) > 0
      rescue => e
        messages = [
            "Connection reset by peer",
            "Service Unavailable"
        ]
        if messages.include?(e.message)
          logger.info("Monit Service Unavailable (#{e.message}): retrying")
          sleep 1
          retry if (attempts -= 1) > 0
        end
        err e
        raise e
      end
    end

    def start_services(attempts=20)
      retry_monit_request(attempts) do |client|
        client.start(:group => BOSH_APP_GROUP)
      end
    end

    def stop_services(attempts=20)
      retry_monit_request(attempts) do |client|
        client.stop(:group => BOSH_APP_GROUP)
      end
    end

    def restart_services(attempts=20)
      retry_monit_request(attempts) do |client|
        client.restart(:group => BOSH_APP_GROUP)
      end
      say "Waiting for services to be online"

      #waiting for the services to be online
      service_state = ""
      i = 0
      for i in 0..10
        sleep 30
        if (service_group_state == "running")
          say "Services Online"
          break
        end

      end
      if (i == 10)
        error_msg = "Infrastructure services did not start did not start"
        raise error_msg
      end
    end

    def service_group_state(num_retries=10)
      # FIXME: state should be unknown if monit is disabled
      # However right now that would break director interaction
      # (at least in integration tests)
      status = get_status(num_retries)

      not_running = status.reject do |name, data|
        # break early if any service is initializing
        return "starting" if data[:monitor] == :init
        # at least with monit_api a stopped services is still running
        (data[:monitor] == :yes && data[:status][:message] == "running")
      end

      not_running.empty? ? "running" : "failing"
    rescue => e
      logger.info("Unable to determine job state: #{e}")
      "unknown"
    end

    def get_status(num_retries=10)
      retry_monit_request(num_retries) do |client|
        client.status(:group => BOSH_APP_GROUP)
      end
    end
  end
end
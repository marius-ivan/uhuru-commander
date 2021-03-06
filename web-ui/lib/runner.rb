require 'rack/reverse_proxy'
require "steno"
require "config"
require "bosh_commander"
require "thin"
require 'optparse'
require "ucc/status_streamer"
require 'yaml'
require 'cgi'
require "products_checker"

# rack session pool
class Rack::Session::Pool
  def initialize app,options={}
    super

    unless $pool != nil
      $pool = Hash.new()
    end

    @pool=$pool
    @mutex=Mutex.new
  end
end

# authentication with rack reverse proxy
class Rack::AuthenticatedReverseProxy < Rack::ReverseProxy
  def call(env)
    rackreq = Rack::Request.new(env)
    matcher = get_matcher rackreq.fullpath

    unless matcher.nil? || env['rack.session']['user_name']
      return [302, {'Location' => '/login/'}, ['Not authenticated - you are being redirected to the login page.']]
    end

    if rackreq.path_info.start_with? '/vmlog-dl/'
      user = env['rack.session']['command'].instance_variable_get('@director').user
      password = env['rack.session']['command'].instance_variable_get('@director').password

      env['HTTP_AUTHORIZATION'] = 'Basic ' + Base64.encode64("#{user}:#{password}").strip
    end

    super
  end
end

module Uhuru::BoshCommander
  # the runner class for the cloud commander
  class Runner
    def self.init_config(file)
      help_file = File.expand_path("../../config/help.yml", __FILE__)
      forms_file = File.expand_path("../../config/forms.yml", __FILE__)

      $config = Uhuru::BoshCommander::Config.from_file(file)
      $config[:help] = load_help_file(help_file)
      $config[:blank_properties_file] = File.expand_path('../../config/properties.yml.erb', __FILE__)
      $config[:properties_file] = File.expand_path('../../config/properties.yml', __FILE__)

      $config[:deployments_dir] = File.expand_path('../../deployments/', __FILE__)
      $config[:configuration_file] = file
      $config[:bind_address] = $config[:bind_address]
      $config[:nagios][:config_path] = File.join($config[:bosh][:base_dir], 'jobs', 'nagios_dashboard', 'config', 'uhuru-dashboard.yml')

      version_file = File.expand_path('../../config/version.yml', __FILE__)
      if File.exists?(version_file)
        $config[:version] = (File.open(version_file) { |file| YAML.load(file)})['version']
      end

      Runner.setup_logging
      $config[:logger] = Runner.logger

      if $config[:mock_backend]
        require "ucc/mock/user"
        require "ucc/mock/bosh"
      else
        require "ucc/user"
      end

      #we need to created the default admin user
      if User.users.size == 0
        User.create("admin", "admin")
        properties = YAML.load_file($config[:properties_file])
        User.create(properties['properties']['hm']['director_account']['user'], properties['properties']['hm']['director_account']['password'])
      end
    end

    # loads the help file for the cloud commander WebUI
    def self.load_help_file(help_file)
      help = File.open(help_file) { |file| YAML.load(file)}

      help.each_key do |key|
        help_items = help[key]

        help[key] = help_items.map do |help_item|
          [help_item['help_item'], help_item['content']]
        end
      end
      help
    end

    def initialize(argv)
      @argv = argv

      # default to production. this may be overridden during opts parsing
      ENV["RACK_ENV"] = "production"
      @config_file = File.expand_path("../../config/config.yml", __FILE__)
      parse_options!
      Runner.init_config @config_file
      Uhuru::BoshCommander::URMHelper.initialize
      Uhuru::BoshCommander::ProductsChecker.start_checking

      create_pidfile
    end

    # defines de logger object
    def self.logger
      $logger ||= Steno.logger("uhuru-cloud-commander.runner")
    end

    def options_parser
      @parser ||= OptionParser.new do |opts|
        opts.on("-c", "--config [ARG]", "Configuration File") do |opt|
          @config_file = opt
        end

        opts.on("-d", "--development-mode", "Run in development mode") do
          # this must happen before requiring any modules that use sinatra,
          # otherwise it will not setup the environment correctly
          @development = true
          ENV["RACK_ENV"] = "development"
        end
      end
    end

    def parse_options!
      options_parser.parse! @argv
    rescue
      puts options_parser
      exit 1
    end

    # create pidfile
    def create_pidfile
      begin
        pid_file = VCAP::PidFile.new($config[:pid_filename])
        pid_file.unlink_at_exit
      rescue
        puts "ERROR: Can't create pid file #{$config[:pid_filename]}"
        exit 1
      end
    end

    def self.setup_logging
      steno_config = Steno::Config.to_config_hash($config[:logging])
      steno_config[:context] = Steno::Context::ThreadLocal.new
      Steno.init(Steno::Config.new(steno_config))
    end

    # runs the WebUI
    def run!
      config = $config.dup

      app = Rack::Builder.new do
        # TODO: we really should put these bootstrapping into a place other
        # than Rack::Builder

        use Rack::CommonLogger
        use Rack::Session::Pool

        use Rack::AuthenticatedReverseProxy do
          # Set :preserve_host to true globally (default is true already)
          reverse_proxy_options :preserve_host => true

          # Forward the path /test* to http://example.com/test*

          tty_js_location = "http://#{$config[:ttyjs][:host]}:#{$config[:ttyjs][:port]}"
          nagios_location = "http://#{$config[:nagios][:host]}:#{$config[:nagios][:port]}"
          director_port = YAML.load_file($config[:properties_file])['properties']['director']['port']
          director_location = "#{$config[:bosh][:target]}:#{director_port}/resources"

          reverse_proxy "/user.js", "#{tty_js_location}/user.js"
          reverse_proxy "/user.css", "#{tty_js_location}/user.css"
          reverse_proxy "/style.css", "#{tty_js_location}/style.css"
          reverse_proxy "/tty.js", "#{tty_js_location}/tty.js"
          reverse_proxy "/term.js", "#{tty_js_location}/term.js"
          reverse_proxy "/options.js", "#{tty_js_location}/options.js"
          reverse_proxy '/socket.io', "#{tty_js_location}/"
          reverse_proxy /^\/ssh(\/.*)$/, "#{tty_js_location}/$1"

          reverse_proxy /^\/vmlog-dl(\/.*)$/, "#{director_location}$1"
          reverse_proxy '/nagios/', "#{nagios_location}/"
          reverse_proxy '/pnp4nagios/', "#{nagios_location}"
        end

        map "/nagios" do
          run Proc.new {|env| [302, {'Location' => '/nagios/'}, ['You are being redirected.']]}
        end

        map "/" do
          run Uhuru::BoshCommander::BoshCommander
        end
      end
      @thin_server = Thin::Server.new('0.0.0.0', $config[:port])
      @thin_server.timeout = 300
      @thin_server.app = app

      trap_signals

      @thin_server.threaded = true
      @thin_server.start!
    end

    def trap_signals
      ["TERM", "INT"].each do |signal|
        trap(signal) do
          @thin_server.stop! if @thin_server
          EM.stop
        end
      end
    end
  end
end

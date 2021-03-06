module Uhuru::BoshCommander
  # Form for configuring a cloud
  class CloudForm < GenericForm

    attr_accessor :deployment

    # Generates volatile data
    #
    def generate_volatile_data!
      super

      auto_complete_manifest!
    end

    # Gets volatile data and sets the values into cloud manifest
    #
    def auto_complete_manifest!
      volatile_manifest = get_data VALUE_TYPE_VOLATILE

      #**************************************************************
      # Setup gateways for used nodes
      #**************************************************************

      gateways = {
          "mysql_gateway" => "mysql_node",
          "mongodb_gateway" => "mongodb_node",
          "redis_gateway" => "redis_node",
          "postgresql_gateway" => "postgresql_node",
          "rabbit_gateway" => "rabbit_node",
          "uhurufs_gateway" => "uhurufs_node",
          "mssql_gateway" => "mssql_node"
      }

      volatile_manifest_jobs = volatile_manifest["jobs"]

      gateways.each{|gateway, node|
        node_exists = volatile_manifest_jobs.find {|job_node| job_node["name"] == node}["instances"].to_i > 0
        volatile_manifest_jobs.find{|job| job["name"] == gateway}["instances"] = node_exists ? 1 : 0
      }

      #**************************************************************
      # Set resource pool sizes based on job instances
      #**************************************************************

      volatile_manifest["resource_pools"].each {|pool|
        pool["size"] = volatile_manifest_jobs.select{ |job| job["resource_pool"] == pool["name"]}.inject(0){|sum_instances, job| sum_instances += job["instances"].to_i}
      }

      #**************************************************************
      # Assign static IP addresses to jobs
      #**************************************************************

      $logger.debug("Starting to assign Static IPs for deployment #{@deployment.deployment_name}")

      jobs_with_static_ips = volatile_manifest_jobs.select do |job_static_ip|
        job_static_ip["networks"][0].has_key?("static_ips")
      end

      $logger.debug("These are all the jobs with a static IP: #{jobs_with_static_ips.map {|job_ip| job_ip['name'] }.inspect}")

      needed_ips = jobs_with_static_ips.inject(0) do |sum, job_ip|
        sum += job_ip["instances"].to_i
      end

      $logger.debug("There are #{needed_ips} required static IPs")

      static_ips = @screens.find {|screen| screen.name == 'Network' }.fields.find{|field| field.name=='static_ip_range'}.get_value(VALUE_TYPE_VOLATILE)
      static_ips = IPHelper.from_string static_ips

      possible_static_ips = IPHelper.get_ips_from_range(static_ips, needed_ips).select do |ip|
        ip_used = volatile_manifest_jobs.any? do |job|
          job_static_ips = job["networks"][0]["static_ips"]
          job_static_ips != nil && job_static_ips.include?(ip)
        end

        !ip_used
      end

      $logger.debug("This is the pool of static IPs we can use: #{possible_static_ips}")

      jobs_with_static_ips.each do |job_with_ip|
        job_with_ip_name = job_with_ip['name']
        job_with_ip["networks"][0]["static_ips"] ||= []

        assigned_ips = job_with_ip["networks"][0]["static_ips"]

        assigned_instances = assigned_ips.size
        needed_instances = job_with_ip["instances"].to_i

        assigned_ips.each_with_index do |static_ip, index|
          if static_ip.to_s.strip == '' || !IPHelper.ip_in_range?(static_ips, static_ip)
            ip = possible_static_ips.shift
            $logger.debug("Replacing static IP #{assigned_ips[index]} with #{ip} for #{job_with_ip_name}")
            assigned_ips[index] = ip
          end
        end

        if needed_instances > assigned_instances
          (assigned_instances..needed_instances-1).each do |index|
            ip = possible_static_ips.shift
            $logger.debug("Assigning static IP #{ip} to #{job_with_ip_name}")
            assigned_ips[index] = ip
          end
        elsif needed_instances < assigned_instances
          diff = assigned_instances - needed_instances
          $logger.debug("Removing #{diff} static IPs from #{job_with_ip_name}")
          assigned_ips.slice!(needed_instances, diff)
        end
      end

      #**************************************************************
      # Set special properties
      #**************************************************************

      properties = volatile_manifest['properties']
      jobs = volatile_manifest_jobs
      networks = volatile_manifest['networks']
      resource_pools = volatile_manifest['resource_pools']

      def jobs.find_by_name(job_name)
        self.find{|job| job['name'] == job_name }
      end

      def resource_pools.find_by_name(pool_name)
        self.find{|pool| pool['name'] == pool_name }
      end

      def jobs.find_by_template(template_name)
        self.find{|job| job['template'].include? template_name }
      end

      def properties.set_val(job, property, value)
        self[job][property] = value
      end

      properties_domain = properties['domain']

      properties.set_val 'nfs_server',        'address',                    jobs.find_by_template('debian_nfs_server')['networks'][0]['static_ips'][0]
      properties.set_val 'nfs_server',        'network',                    networks[0]['subnets'][0]['range']
      properties.set_val 'syslog_aggregator', 'address',                    jobs.find_by_template('syslog_aggregator')['networks'][0]['static_ips'][0]
      properties.set_val 'nats',              'address',                    jobs.find_by_template('nats')['networks'][0]['static_ips'][0]
      properties.set_val 'ccdb',              'address',                    jobs.find_by_name('ccdb')['networks'][0]['static_ips'][0]
      properties.set_val 'cc',                'srv_api_uri',                "api.#{properties_domain}"
      properties.set_val 'vcap_redis',        'address',                    jobs.find_by_template('vcap_redis')['networks'][0]['static_ips'][0]
      properties.set_val 'vcap_redis',        'maxmemory',                  resource_pools.find_by_name('medium')['cloud_properties']['ram']
      properties.set_val 'router',            'redirect_parent_domain_to',  "www.#{properties_domain}"
      properties.set_val 'dea',               'maxmemory',                  resource_pools.find_by_name('deas')['cloud_properties']['ram']

    end

    # Load a deployment configuration from a previous exported manifest
    # cloud_name = name of the cloud to be deployed
    # imported_data =
    #
    def self.from_imported_data(cloud_name, imported_data)
      unless (defined? Thread.current.request_id) && (Thread.current.request_id != nil)
        raise "This method has to be called using a 'Commander BOSH Runner'"
      end

      CloudForm.new(imported_data, nil, Deployment.new(cloud_name))
    end

    # Load a deployment configuration from a previous manifest by cloud name
    # cloud_name = name of the cloud deployment
    # form_data = data displayed on the form
    #
    def self.from_cloud_name(cloud_name, form_data)
      unless (defined? Thread.current.request_id) && (Thread.current.request_id != nil)
        raise "This method has to be called using a 'Commander BOSH Runner'"
      end

      deployment_yml = File.join($config[:deployments_dir], cloud_name, "#{cloud_name}.yml")

      saved_data = nil
      if File.exists? deployment_yml
        saved_data = YAML.load_file(deployment_yml)
      end

      CloudForm.new(saved_data, form_data, Deployment.new(cloud_name))
    end

    private

    # Private initializer to populate from deployment to data displayed on form and saved data
    # saved_data = saved data to be initialized
    # form_data = data displayed on the form
    # deployment = deployment manifest file from where data is loaded
    #
    def initialize(saved_data, form_data, deployment)
      @deployment = deployment
      live_data = @deployment.get_manifest

      super('cloud', saved_data, form_data, live_data)
    end
  end
end

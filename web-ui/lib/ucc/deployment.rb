module Uhuru::BoshCommander

  class Deployment

    STATE_DEPLOYING = "Deploying"
    STATE_ERROR = "Error"
    STATE_DEPLOYED = "Deployed"
    STATE_SAVED = "Saved"
    STATE_NOT_CONFIGURED = "Not Configured"

    attr_reader :deployment_name
    attr_reader :deployment_dir
    attr_reader :deployment_manifest_path

    def initialize(deployment_name)
      @deployment_name = deployment_name
      @deployment_dir = File.join($config[:deployments_dir], deployment_name)
      @deployment_manifest_path = File.join("#{@deployment_dir}","#{deployment_name}.yml")
      @lock_file = File.join("#{@deployment_dir}","deployment.lock")
      #create deployment folder
      if (Dir["#{@deployment_dir}"].empty?)
        Dir.mkdir @deployment_dir
      end
    end

    #saves the deployment manifest
    def save(deployment_manifest)
      @manifest = deployment_manifest
      @manifest["name"] = @deployment_name

      #set director UUID
      director = Thread.current.current_session[:command].instance_variable_get("@director")
      @manifest["director_uuid"] =  director.uuid

      #write the file
      File.open(@deployment_manifest_path, 'w') do |out|
        YAML.dump(@manifest, out)
      end
    end

    #Returns an array of all the deployments
    def self.deployments
      folders = Dir.entries($config[:deployments_dir]).select do |entry|
        !(entry == '.' || entry == '..' || File.file?(File.join($config[:deployments_dir], entry))) &&
            (File.file?(File.join($config[:deployments_dir], entry, "#{entry}.yml")))
      end
      folders
    end

    def self.deployments_obj
      deployments.map do |deployment|
        Deployment.new(deployment)
      end
    end

    def self.get_deployment_path(deployment_name)
      File.join($config[:deployments_dir], deployment_name)
    end

    def self.get_deployment_yml_path(deployment_name)
      File.join(get_deployment_path(deployment_name), "#{deployment_name}.yml")
    end

    #start the deployment process
    def deploy()

      if File.exists? @lock_file
         say "Deployment in process, please check tasks"
        return
      end

      File.open(@lock_file, 'w') {|f| f.write("locked") }
      command = deployment_command
      current_file = File.join(@deployment_dir, "#{@deployment_name}.yml")
      command.set_current(current_file)
      command.perform

      File.delete(@lock_file)

      say "Deployment finished".green

    end

    #retrieves deployment information
    def status
      state = get_state
      current_manifest = nil
      if state == STATE_DEPLOYED
        current_manifest = get_manifest()
      elsif state == STATE_ERROR
        return {}
      else
        current_manifest = load_yaml_file(@deployment_manifest_path)
      end

      stats = {}

      unless (state == STATE_ERROR) || (state == STATE_NOT_CONFIGURED)
        stats["resources"] = get_resources(current_manifest)

        current_manifest["jobs"].each do |job|
          if job["name"] == "router"
            stats["router_ips"] = []
            static_ips = []
            job["networks"].each do |network|
              network["static_ips"].each do |ip|
                static_ips << ip
              end
            end
            stats["router_ips"] << static_ips
          end
        end
      end

      properties = current_manifest["properties"]
      stats["name"] = self.deployment_name
      stats["state"] = state
      stats["api_url"] = properties["cc"]["srv_api_uri"]
      stats["uaa_url"] = properties["uaa_endpoint"]
      stats["web_ui_url"] = "www.#{properties["domain"]}"
      stats["admin_email"] = properties["uhuru"]["simple_webui"]["admin_email"]
      stats["contact_email"] = properties["uhuru"]["simple_webui"]["contact"]["email"]
      stats["support_url"] = properties["support_address"]
      stats["services"] = ["mysql_node", "mssql_node", "uhurufs_node", "rabbit_node", "postgresql_node", "redis_node", "mongodb_node"].map { |node|
        current_manifest["jobs"] != nil && current_manifest["jobs"].select{|job| job["name"] == node}.first["instances"] > 0 ? node : nil }.compact
      stats["stacks"] = ["dea", "win_dea"].map { |stack|
        current_manifest["jobs"] != nil && current_manifest["jobs"].select{|job| job["name"] == stack}.first["instances"] > 0 ? stack : nil }.compact

      stats
    end


    #the VMs and deployment manifests are deleted.
    def delete()
      state = get_state
      if state != STATE_SAVED
        tear_down
      end

      #clean the files on disk
      FileUtils.rm_rf "#{@deployment_dir}"
      say "Deployment deleted".green
    end

    #returns the deployment manifest. If save_as is provided, also saves the deployment manifest to a flie
    def get_manifest(save_as = nil)
      state = get_state
      if state != STATE_DEPLOYED
        return nil
      end

      director = Thread.current.current_session[:command].instance_variable_get("@director")
      deployment = director.get_deployment(@deployment_name)

      if save_as
        File.open(save_as, "w") do |f|
          f.write(deployment["manifest"])
        end
      end

      if deployment["manifest"] == nil
        return nil
      end

      YAML.load(deployment["manifest"])
    end

    #delete VMs corresponding to this deployment
    def tear_down()
      #delete deployment
      command = deployment_command
      command.delete(@deployment_name)
    end

    def get_state

      unless File.exist?(File.expand_path("../../../cf_deployments/#{ self.deployment_name }/#{ self.deployment_name }.yml", __FILE__))
        return STATE_ERROR
      end

      director =  Thread.current.current_session[:command].instance_variable_get("@director")
      deployments = director.list_deployments

      local_manifest = false
      local_manifest = true if (File.exist? @deployment_manifest_path)

      remote_manifest = nil

      deployment_locked = true if (File.exist? @lock_file)

      #determine if director contains the deployment
      director_deployment = false
      unless deployments.empty?
        deployments.each do |d|
          if d["name"] == @deployment_name
            director_deployment = true
            remote_manifest = director.get_deployment(@deployment_name)["manifest"]
            break
          end
        end
      end

      if director_deployment
        if local_manifest
          if (deployment_locked)
            STATE_DEPLOYING
          else
            if (remote_manifest)
              STATE_DEPLOYED
            else
              STATE_ERROR
            end
          end
        else
          STATE_ERROR
        end
      else
        if local_manifest
          manifest = File.open(@deployment_manifest_path) { |file| YAML.load(file)}
          gateway = manifest['networks'][0]['subnets'][0]['gateway']
          if (gateway == nil) || (gateway.strip == '')
            STATE_NOT_CONFIGURED
          else
            STATE_SAVED
          end
        else
          STATE_ERROR
        end
      end
    end

    private

    def get_resources(deployment_manifest)
      result = {}
      total_cpu = 0
      total_ram = 0
      total_disk = 0
      deployment_manifest["resource_pools"].each do |resource_pool|
        total_cpu +=  resource_pool["cloud_properties"]["cpu"].to_i * resource_pool["size"].to_i
        total_ram += resource_pool["cloud_properties"]["ram"].to_i * resource_pool["size"].to_i
        total_disk += (get_stemcell_disk(resource_pool["stemcell"]) + resource_pool["cloud_properties"]["disk"].to_i) * resource_pool["size"].to_i
      end
      deployment_manifest["jobs"].each do |job|
        total_disk += job["persistent_disk"].to_i * job["instances"].to_i
      end
      result["total_cpu"] = total_cpu
      result["total_RAM"] = total_ram
      result["total_disk"] = total_disk
      result
    end

    def get_stemcell_disk(stemcell)
      $config[:bosh][:stemcells].each do |stemcell_type, config_stemcell|
        if config_stemcell[:name] == stemcell["name"] && config_stemcell[:version] == stemcell["version"]
          return config_stemcell[:system_disk].to_i
        end
      end
      0
    end

    def deployment_command
      command = Thread.current.current_session[:command]
      deployment_cmd = Bosh::Cli::Command::Deployment.new
      deployment_cmd.instance_variable_set("@options", command.instance_variable_get("@options"))
      deployment_cmd
    end
  end
end

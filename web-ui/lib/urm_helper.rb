module Uhuru::BoshCommander
  class URMHelper

    class << self;
      attr_accessor :username, :endpoint, :port
    end

    def self.initialize
      @userhost = `cat /etc/apt/sources.list | grep "arch=amd64" | grep "ssh://" | awk '{print $3}' | cut -f 3 -d \/|cut -f 1 -d \:`

      @userhost = @userhost.gsub("\n",'')
      @username, sep, @endpoint = @userhost.partition("@")
      @port = `cat ~/.urm_port`
    end

    # ssh on urm machine, make a local http get to create the manifest and copy manifest to destination
    #
    def self.copy_manifest(endpoint_name, manifest_name,destination_path)
      `ssh #{@userhost} "curl --interface lo http://localhost:#{@port}/#{@username}/#{endpoint_name} 2>/dev/null"`

      `rsync -avz -e ssh #{@userhost}:~/#{manifest_name} #{destination_path}`

    end

  end
end
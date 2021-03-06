require 'fileutils'
require 'yaml'

module Uhuru
  module BoshCommander
    module Versioning
      # the product class for the ucc product
      class Product
        BLOBSTORE_ID_PRODUCTS = "products.yml"

        TYPE_STEMCELL = 'stemcell'
        TYPE_SOFTWARE = 'software'
        TYPE_UCC = 'ucc'

        attr_accessor :name
        attr_accessor :label
        attr_accessor :description
        attr_accessor :versions
        attr_accessor :local_versions
        attr_accessor :type
        attr_accessor :latest_version

        @@semaphore = Mutex.new

        # sets de versioning directory
        def self.version_directory
          dir = $config[:versioning][:dir]
          FileUtils.mkdir_p(dir)
          dir
        end

        # returns all products
        def self.get_products
          dir = Product.version_directory
          products_yaml_file = File.join(dir, 'products.yml')
          products_yaml = {}
          products_yaml_exists = false

          Product.versions_semaphore.synchronize do
            products_yaml_exists = File.exist? products_yaml_file
            if products_yaml_exists
              products_yaml = YAML.load_file(products_yaml_file)
            end
          end

          if products_yaml_exists
            products = {}
            products_yaml['products'].each do |product, details|
              products[product] = Product.new(product, details['label'], details['type'], details['description'])
            end
            products
          else
            {}
          end
        end

        # returns the blobstore client
        def self.get_blobstore_client
          bsc_provider= "sftp"
          bsc_options= {:endpoint => Uhuru::BoshCommander::URMHelper.endpoint, :user => Uhuru::BoshCommander::URMHelper.username, :blobstore_path => Uhuru::BoshCommander::URMHelper.urm_home_dir}
          Bosh::Blobstore::Client.create(bsc_provider, bsc_options)
        end

        def self.versions_semaphore
          @@semaphore
        end

        def self.download_manifests
          dir = Product.version_directory
          temp_dir = Dir.mktmpdir
          products_yaml_file = File.join(temp_dir, BLOBSTORE_ID_PRODUCTS)
          products_temp_file = File.join(temp_dir, "#{BLOBSTORE_ID_PRODUCTS}.tmp")
          
          Uhuru::BoshCommander::URMHelper.copy_manifest("products", BLOBSTORE_ID_PRODUCTS, products_temp_file)

          if File.exists?(products_temp_file)
            FileUtils.mv(products_temp_file, products_yaml_file)
          end

          products_yaml = YAML.load_file(products_yaml_file)

          products_yaml['products'].each do |product_name, product_details|
            product_dir = File.join(temp_dir, product_name)
            Dir.mkdir product_dir
            versions_manifest_yaml_file = File.join(product_dir, 'manifest.yml')
            versions_manifest_temp_file = "#{versions_manifest_yaml_file}.tmp"
            Uhuru::BoshCommander::URMHelper.copy_manifest(product_name, "#{product_name}_manifest.yml", versions_manifest_temp_file)
            versions_info = YAML.load_file(versions_manifest_temp_file)
            versions_info['versions'].each do |_, version|
              unless get_blobstore_client.exists?(version['location']['object_id'])
                version['location']['missing'] = true
              end
            end

            File.open(versions_manifest_yaml_file, "w") do |file|
              file.write versions_info.to_yaml
            end
          end

          Product.versions_semaphore.synchronize do
            FileUtils.cp_r Dir.glob("#{temp_dir}/*"), dir
          end
        ensure
          FileUtils.rm_rf(temp_dir)
        end

        def initialize(name, label, type, description)
          @name = name
          @label = label
          @description = description
          @type = type

          dir = Product.version_directory
          versions_manifest_file = File.join(dir, @name, 'manifest.yml')

          @versions = {}
          @local_versions = {}


          versions_manifest_exists = false
          versions_manifest = {}
          Product.versions_semaphore.synchronize do
            versions_manifest_exists = File.exist?(versions_manifest_file)
            if versions_manifest_exists
              versions_manifest = YAML.load_file(versions_manifest_file)
            end
          end

          if versions_manifest_exists
            versions_manifest['versions'].each do |version, details|
              version_obj = Version.new(self, version, details)

              if !version_obj.missing || (File.exist?(version_obj.bits_full_local_path) || Dir.exist?(version_obj.bits_full_local_path))
                @versions[version] = version_obj

                if File.exist?(@versions[version].bits_full_local_path) || Dir.exist?(@versions[version].bits_full_local_path)
                  @local_versions[version] = @versions[version]
                end
              end
            end

            @latest_version = @versions.values.max
          end
        end
      end
    end
  end
end

require 'fileutils'
require 'yaml'
require 'erb'
require 'pp'
require 'json'

source_dir = ARGV[0]
destination = ARGV[1]

module Bosh

end

require 'ostruct'

puts 'Loading configuration scripts...'

require File.join(source_dir, 'properties/errors.rb')
require File.join(source_dir, 'properties/property_helper.rb')
require File.join(source_dir, 'properties/template_evaluation_context.rb')

puts "Creating destination directory (#{destination})..."
FileUtils.mkdir_p(destination)

spec_file = File.join(source_dir, 'spec')

puts "Loading spec file (#{spec_file})..."
spec = YAML.load_file(spec_file)
defaults = YAML.load_file(File.join(source_dir, 'defaults.yml'))

properties = {}
properties['job'] = { 'name' => spec['name'] }
properties['index'] = 0
properties['properties'] = defaults['properties']



if ENV
  ENV.each do |p_name, p_value|
    if p_name.start_with?('uhuruconfig.')

      before_last = nil
      final_particle = nil
      last = properties['properties']
      default_value = defaults['properties']
      p_name.split('.').each do |particle|
        last[particle] ||= {}
        before_last = last
        last = last[particle]
        final_particle = particle
        if default_value
          default_value = default_value[particle]
        end
      end

      before_last[final_particle] = ENV["uhuru.#{p_name}"]
    end
  end
end

puts 'Using the following properties:'
pp properties['properties']

spec['templates'].each do |template_source, template_destination|
  puts "Processing template file (#{template_destination})..."

  template_file = File.join(source_dir, 'templates', template_source)
  template_contents = ERB.new File.new(template_file).read

  template_destination_file = File.join(destination, template_destination)
  FileUtils.mkdir_p(File.expand_path('..', template_destination_file))

  spec_binding = Bosh::Common::TemplateEvaluationContext.new(properties).get_binding

  File.open(template_destination_file, 'w') do |file|
    file.write(template_contents.result(spec_binding))
  end

  `chmod +x #{template_destination_file}`
end

puts 'Processing monit file...'
template_file = File.join(source_dir, 'monit')
template_contents = ERB.new File.new(template_file).read
template_destination_file = template_file
spec_binding = Bosh::Common::TemplateEvaluationContext.new(properties).get_binding
File.open(template_destination_file, 'w') do |file|
  file.write(template_contents.result(spec_binding))
end

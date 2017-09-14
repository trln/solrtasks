require 'solrtasks'
require 'yaml'
require 'cocaine'
require 'pp'

RAILS_CONFIG = 'config/solrtask.yml'.freeze

logger = defined? Rails ? Rails.logger : Logger.new($stderr)

config = {}
if defined?(Rails)
  rails_environment = Rails.env || 'development'
  config_file = File.join(Rails.root, RAILS_CONFIG)
  if File.exist?(config_file)
    # load with alias support
    config = File.open(config_file) { |f| YAML.safe_load(f,[],[],true)[rails_environment] }
    logger.warn "Unable to find configuration for environment '#{rails_environment}', using defaults" if config.empty?
  else
    logger.debug "No #{RAILS_CONFIG} found, using defaults"
  end
else
  config_file = ENV['SOLRTASK_CONFIG'] || 'solrtask.yml'
  if File.exist?(config_file)
    config = File.open(config_file) { |f| YAML.safe_load(f) }
    logger.debug 'No solrtask.yml config file found, using defaults'
  end
end

server = SolrTasks::Server.new(config) unless config.empty?

server ||= SolrTasks::Server.new

desc 'Tasks for Solr installlation, start/stop and schema management'
namespace :solrtask do
  unless Rake::Task.task_defined?(':environment')
    desc "Stub 'environment' task when we're not running under Rails"
    task :environment do
      # pass
    end
  end

  desc 'Shows configuration, including computed values'
  task show_config: :environment do
    logger.info "Base confguration loaded from #{config_file}" if File.exist?(config_file)
  end

  desc 'Lists available collections'
  task collections: :environment do
    colls = server.get_collections
    if colls.empty?
      logger.warn 'No collections found'
    else
      puts 'Collections:'
      colls.each do |c|
        puts "\t#{c}"
      end
    end
  end

  desc 'Installs solr (if necessary)'
  task install: :environment do
    unless File.exist?(server.install_dir)
      f = SolrTasks::Fetcher.new(server.install_dir, server.version)
      f.install
    end
  end

  desc 'Stops solr if is running '
  task stop: %i[environment install] do
    server.stop if server.is_running?
  end

  desc 'Ensures solr is running'
  task start: %i[environment install] do
    if server.is_running?
      logger.info "Solr is already running on port #{server.port}"
    else
      server.start unless server.is_running?
    end
  end

  task :create_collection, [:collection_name] => [:start] do |_t, args|
    collection = args[:collection_name]
    if server.collection_exists?(collection)
      logger.warn "Collection '#{collection}' already exists'"
    else
      server.create_collection(collection)
      logger.info "Collection '#{collection}'' created.  You may now add files to the index"
    end
  end

  desc "Creates a 'data driven' core with a managed schema"
  task :create_core, [:core_name] => %i[environment start] do |_t, args|
    core = args[:core_name]
    if server.core_exists?(core)
      logger.warn "Core '#{core}'' already exists."
    else
      server.create_core(core)
      logger.info "Core '#{core}' created.  You may now add files to the index"
    end
  end

  desc 'Outputs the schema for the named core/collection'
  task :show_schema, [:schema] => %i[environment start] do |_t, args|
    server.show_schema(args[:schema])
  end

  desc 'Lists fields for a given core/collection'
  task :list_fields, [:schema] => %i[environment start] do |_t, args|
    puts "Schema '#{args[:schema]}':"
    sf = server.get_fields(args[:schema])
    %i[fields dynamicFields].each do |ft|
      puts ft == :fields ? 'Fields: ' : 'Dynamic Fields:'
      sf[ft].each do |f|
        puts "\t#{f[:name]} : #{f[:type]}"
      end
    end
  end

  desc 'Harmonizes a core/collection schema with one defined in YAML'
  task :harmonize_schema, %i[schema config_file] => %i[environment start] do |_t, args|
    puts "Harmonizing #{args[:schema]} with #{args[:config_file]}"
    server.harmonize_schema(args[:schema], args[:config_file])
  end

  desc 'Unloads (deletes) core (DANGEROUS)'
  task :delete_core, [:core_name] => %i[environment start] do |_t, args|
    core = args[:core_name]
    if server.core_exists?(core)
      server.delete_core
      puts 'DELETED!'
    end
  end

  desc 'Creates a Solr distribution that includes extra (local) library files'
  task :add_libraries, [:library_files] => %i[environment] do |_t, args|
    library_files = args[:library_files]
    library_files = [library_files] unless library_files.is_a?(Array)
    library_files.map do |x|
      if File.directory?(x)
        [Dir.glob("#{x}/*.jar")]
      elsif File.exist?(x)
        x
      end
    end.flatten
    if library_files.empty? 
      puts "No library files to add.  Cannot continue"
      exit 1
    end
    library_files.each do |x|
      puts "Adding #{x} to solr distributes"
    end
    f = SolrTasks::Fetcher.new(server.install_dir, server.version)
    f.install(false) unless File.exist?(f.target)
    SolrTasks::Repacker.add_libraries(
       f.target,
       "solr-enhanced-#{server.version}.tgz",
      library_files)
  end
end

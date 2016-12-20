require 'solrtasks'
require 'yaml'
require 'cocaine'

if defined?(Rails) 
    rails_environment=Rails.env || 'development'
    config_file = File.join(Rails.root, "config/solr.yml")
    if File.exist?(config_file)
    else 
        Rails.logger.warn "No config/solr.yml found, using defaults"        
    end
    say = lambda { |msg| Rails.logger.info msg }
else
    config_file = ENV['SOLR_CONFIG'] || 'solr.yml'
    if File.exist?(config_file)
        server = SolrTasks::Server.from_file(config_file)
    else
        puts "No solr.yml config file found, using defaults"  
    end
    say = puts

end

server ||= SolrTasks::Server.new

desc "Tasks for Solr installlation, start/stop and schema management"
namespace :solrtask do    
    solr_port = server.port

    desc "Lists available collections"
    task :collections => :environment do
        colls = server.get_collections
        if colls.empty?
            puts "No collections found"
        else
            puts "Collections:"
            colls.each do |c|
                puts "\t#{c}"
            end
        end
    end

    desc "Installs solr (if necessary)"
    task :install => :environment do
        if not File.exist?(server.install_dir)	
            f = SolrTasks::Fetcher.new(server.install_dir, server.version)
            f.install
        end
    end

    desc 'Stops solr if is running '
    task :stop => [ :environment, :install ] do
        server.stop if server.is_running?
    end

    desc "Ensures solr is running"
    task :start => [ :environment, :install ] do
        if server.is_running?
            say "Solr is already running on port #{server.port}"
        else
            server.start unless server.is_running?
        end
    end

    task :create_collection, [:collection_name] => [:start] do |t,args|
        collection = args[:collection_name]
        if server.collection_exists?(collection)
            say "Collection '#{collection}' already exists'"
        else
            server.create_collection(collection)
            say "Collection '#{collection}'' created.  You may now add files to the index"
        end
    end

    desc "Creates a 'data driven' core with a managed schema"
    task :create_core, [ :core_name] => [ :environment, :start ] do |t,args|
        core = args[:core_name]
        if server.core_exists?(core)
            say "Core '#{core}'' already exists."
        else 
            server.create_core(core)
            say "Core '#{core}' created.  You may now add files to the index"
        end
    end

    desc "Outputs the schema for the named core/collection"
    task :show_schema,  [ :schema ] => [ :environment, :start ] do |t,args|
        server.show_schema(args[:schema])
    end

    desc "Lists fields for a given core/collection"
    task :list_fields, [ :schema ] => [ :environment, :start ] do |t,args|
        puts "Schema '#{args[:schema]}':"
        sf = server.get_fields(args[:schema])
        [ :fields, :dynamicFields ].each do |ft|
            puts ft == :fields ? "Fields: " : "Dynamic Fields:"
            sf[ft].each do |f|
                puts "\t#{f[:name]} : #{f[:type]}"
            end
        end
    end

    desc "Unloads (deletes) core (DANGEROUS)"
    task :delete_core, [ :core_name ] => [ :environment, :start ] do |t,args|
        core = args[:core_name]
        if server.core_exists?(core)
            server.delete_core
            puts "DELETED!"
        end
    end
end 


module SolrTasks
    # Makes rake tasks available automatically when this gem is used by a Rails application
    class Railtie < Rails::Railtie
        rake_tasks do
            task_file = File.expand_path(File.join(__FILE__,'../../tasks/solr.rake'))
            load task_file
        end
    end
end

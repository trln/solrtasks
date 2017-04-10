require 'rake'

module SolrTasks
    class Tasks
        include Rake::DSL if defined? Rake::DSL
        def install_tasks
            load 'tasks/solr.rake'
        end
    end
end

SolrTasks::Tasks.new.install_tasks

require "solrtasks/version"
require 'solrtasks/server'

# load Railtie if we're running under Rails
require 'solrtasks/railtie' if defined?(Rails)

# SolrTasks provides a number of features for working with a Solr server installation, mostly for purposes
# of enabling quick, programmatic setup of Solr servers, cores, and collections.  It probably won't help you
# manage a production instance, but it might give you some ideas.
module SolrTasks
end

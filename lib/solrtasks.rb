require 'logger'
require 'yaml'
require 'net/http'
require 'rubygems'
require 'rubygems/package'
require 'net/http'
require 'net/https'
require 'open-uri'
require 'uri'
require 'digest/sha1'
require 'fileutils'
require 'zlib'
require 'nokogiri'
require 'json'
require 'cocaine'

require 'solrtasks/version'

# load Railtie if we're running under Rails
require 'solrtasks/railtie' if defined?(Rails)

# SolrTasks provides a number of features for working with a Solr server
# installation, mostly for purposes of enabling quick, programmatic setup of
# Solr servers, cores, and collections.  It probably won't help you
# manage a production instance, but it might give you some ideas.
module SolrTasks
  autoload(:Server, 'solrtasks/server')
  autoload(:Fetcher, 'solrtasks/fetcher')
  autoload(:Extractor, 'solrtasks/extractor')
  autoload(:Repacker, 'solrtasks/repacker')
  autoload(:Schema, 'solrtasks/schema')

  class << self
    attr_accessor :logger
  end

  self.logger = Logger.new(STDOUT)
end

# SolrTasks

A Ruby gem that provides some tools for installing, configuring, and running an (Apache Solr)[https://lucene.apache.org/solr] instance.  Includes
rake tasks and a Railtie to make those tasks avaialble when this gem is used in a Rails application.  There is also a command line tool, which is mostly 
useful for automating the download.

## Installation

```ruby
gem 'solrtasks'
```

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install solrtasks

## Usage

There are three modes of usage: as a set of `rake` tasks (in the `solrtask` namespace), as a library that helps you programatically install/start/stop Solr, and a command line tool that provides a front end to some of the library's functionality.

The installer process performs SHA-1 verification on any package it downloads, and caches the downloaded files in `$HOME/.solrtask` to reduce network traffic from busy developers' machines.

### Script

`solrtask` mainly allows for installing, stopping, starting, and status checking from the command line.  It also lets you query for collections, cores, schemas, 
   and field names.  
    
    $ solrtask -h 

Provides help on how to use this script, but here's a few samples:

     $ solrtask install # installs solr under ./solr-dir/solr-VERSION if it isn't already installed there
     $ solrtask start # starts a local solr
     $ solrtask stop # stops a local solr
     $ solrtask collections # gets list of collections
     $ solrtask fields my_collection # gets field and field type information for my_collection
     $ solrtask schema my_collection # download the schema for my_collection

Most of these are intended to interact with a Solr server running on the same host (they wrap the main `solr` script from the distribution), but you can also use this tool (with the `-u/--url=` argument) along with `collections`, 'fields`, or `schema` to query a remote solr server.

### Rake tasks

Rake tasks are automatically made available to a Rails application that uses this gem.  For other kinds of application in which you want to access the tasks, try these [instructions from Andy Atkinson](http://andyatkinson.com/blog/2014/06/23/sharing-rake-tasks-in-gems).  Once you've got the tasks loading, you 
can view them via `rake --tasks` (or `bundle exec rake --tasks`) -- they are in the `solrtask` namespace.

### Library

`SolrTasks::Server` is the primary class for interacting with a Solr server, but you might want to use `SolrTasks::Fetcher` to help automate installs.  View the source code or generate documentation with `yard` for more information on usage.

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/trln/solrtasks.

## Copyright

The contents of this gem are in no way endorsed, sponsored by, or affiliated with Apache Solr or the Apache Software Foundation.


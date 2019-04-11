# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'solrtasks/version'

Gem::Specification.new do |spec|
  spec.name          = "solrtasks"
  spec.version       = SolrTasks::VERSION
  spec.authors       = ["Adam Constabaris"]
  spec.email         = ["adam_constabaris@ncsu.edu"]

  spec.summary       = %q{Rake tasks for Solr server management.}
  spec.description   = %q{A library and Rake tasks for handling Solr installations, including downloading (and verifying) Solr versions, starting/stopping servers,
    collection creation, and some tools for schema management.}
  #spec.homepage      = "TODO"

  # Prevent pushing this gem to RubyGems.org. To allow pushes either set the 'allowed_push_host'
  # to allow pushing to a single host or delete this section to allow pushing to any host.
  if spec.respond_to?(:metadata)
    spec.metadata['allowed_push_host'] = "TODO: Set to 'http://mygemserver.com'"
  else
    raise "RubyGems 2.0 or newer is required to protect against public gem pushes."
  end

  spec.files         = `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_runtime_dependency 'nokogiri', '>= 1.10'
  spec.add_runtime_dependency 'cocaine', '~> 0.5.8'

  spec.add_development_dependency "bundler", ">= 1.16"
  spec.add_development_dependency "rake", "~> 12"
  spec.add_development_dependency "rspec", "~> 3.0"
end

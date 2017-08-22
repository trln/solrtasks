module SolrTasks
  DEFAULT_CONFIG = {
    version: '6.6.0',
    local: true,
    uri_base: 'http://localhost:8983/solr/',
    install_base: File.expand_path('./solr-versions/')
  }.freeze

  # Utilities for working with a Solr installation.  Supports:
  #    * Download
  #    * Installation
  #    * start/stop
  #    * core/collection creation
  #    * core/collection deletion
  #    * schema query and (some) manipulation
  #
  #   These utilties are not intended to support long-term maintenance of a Solr or SolrCloud installation, but
  #   are instead meant to ease the setup of Solr-based applications for development, testing, or very small
  #   turnkey application installations.
  #
  # @!attribute base_uri [rw]
  #   @return [String] the base URI to the Solr instance (usually ends with `/solr`)
  # @!attribute port [rw]
  #    @return [String] the port Solr is listening on (default: extract from :base_uri)
  # @!attribute install_dir [rw]
  #   @return [String] the parent directory for the Solr server installation
  # @!attribute version [rw]
  #   @return [String] the Solr version we are working with.
  # @!attribute solr_cmd [r]
  #   @return [String] the path to the 'solr' binary used to start/stop the instance
  class Server
    attr_accessor :base_uri, :port, :install_dir, :instance_dir, :version
    attr_reader :solr_cmd, :config, :local

    # Loads a new instance with configuration taken from a file in YAML format.  See
    #
    def self.from_file(config_file, environment = nil)
      raise "File #{config_file} does not exist" unless File.exist?(config_file)
      config = File.open(config_file) do |f|
        YAML.safe_load(f)
      end
      config = config[environment] if environment
      logger.warn "configuration section '#{environment} not found in YAML file" unless config
      Server.new(config)
    end

    # Creates a new instance
    # @param options [Hash] the options hash.  iIf empty, DEFAULT_OPTIONS will be used.
    # @option options [String] :uri_base the base URI to the solr instance (usually ends with `/solr`), including the hostname
    #               and protocol (http/https). (the `port` attribute will be computed from this)
    # @option options [Boolean] :local whether the server can be managed with local commands
    # @option options [String] :version the Solr version we are working with.
    # @option options [String] :install_base the base directory for downloaded servers, binaries, etc.  `:install_dir`
    #               will be set to `@install_base/solr-@version` unless the :install_dir option is provided.
    # @option options [String] :install_dir the full path to an unpacked Solr directory (optional if :install-base is set)
    #
    # @see Fetcher
    # @see Extractor
    def initialize(options = {})
      defaults = Marshal.load(Marshal.dump(DEFAULT_CONFIG))
      # merge in any passed in options over defaults, converting keys to symbols
      @config = Hash[defaults.merge(options).map { |(k, v)| [k.to_sym, v] }]
      @local = @config[:local]
      uri_base = @config[:uri_base]
      uri_base += '/' unless uri_base.end_with?('/')
      @base_uri = URI(uri_base)
      @port = @base_uri.port
      @version = @config[:version]
      @install_dir =  options[:install_dir] || File.absolute_path(@config[:install_base])
      @instance_dir = File.join(@install_dir, "solr-#{@version}/")
      @solr_cmd = File.join(@instance_dir, 'bin/solr')
      @config.update(install_dir: @install_dir, solr_cmd: @solr_cmd, port: @port, version: @version)
      @logger = options[:logger] || SolrTasks.logger
      Cocaine::CommandLine.logger = @logger if @config[:verbose]
    end

    # Checks whether the server is running
    # Note this requires that the 'lsof' utility be installed.  This only works on *nix
    # systems.
    def is_running?
      begin
          uri = URI(@base_uri)
          Net::HTTP.start(uri.host, uri.port) do |http|
            http.open_timeout = 1
            http.read_timeout = 1
            http.head(uri.path)
          end
          return true
        rescue
          return false unless @config[:local]
        end

      # as a backup when running locally, see if something's
      # holding the port open
      line = Cocaine::CommandLine.new(
        'lsof -i', ':portspec', expected_outcodes: [0, 1]
      )
      begin
        puts "Checking port: #{@port}"
        output = line.run(portspec: ":#{@port}")
        # lsof has output if something's holding the port open
        return !output.empty?
      rescue Cocaine::ExitStatusError => e
        @logger.error "Unable to execute #{line} : #{e.message}"
        exit 1
      end
    end

    # Get the names of all cores in the Solr instance
    # @return [Array<String>]
    def get_cores
      uri = admin_uri('cores')
      uri.query = 'action=LIST&wt=json'
      res = Net::HTTP.get_response(uri)
      if res.is_a?(Net::HTTPSuccess)
        data = JSON.parse(res.body)
        return data.key?('cores') ? data['cores'] : []
      else
        SolrTasks.logger.error res.body
        exit 1
      end
    end

    # Checks whether a core with a given name exists
    # # @param core_name [String] the name of the core
    # @return [Boolean]
    def core_exists?(core_name)
      get_cores.include?(core_name)
    end

    # get the names of all collections in the solr instance
    # @return [Array<String>]
    def get_collections
      uri = admin_uri
      uri.query = 'action=LIST&wt=json'
      res = Net::HTTP.get_response(uri)
      if res.is_a?(Net::HTTPSuccess)
        data = JSON.parse(res.body)
        return data.key?('collections') ? data['collections'] : []
      else
        SolrTasks.logger.error res.body
        exit 1
      end
    end

    # Get the schema for a given core or collection
    # @param cname [String] the name of the core or collection
    # @param ['json', 'xml', 'schema.xml'] the format for the schema document
    # @return [String] the content of the schema
    def get_schema(cname, format)
      uri = URI.join(@base_uri, "#{cname}/schema")
      uri.query = "wt=#{format}"
      resp = Net::HTTP.get_response(uri)
      return resp.body if resp.is_a?(Net::HTTPSuccess)
      @logger.warn "Unexpected response body: \n\n\n#{resp.body}\n\n------\n"
      raise "Schema fetch failed: #{resp.code} : #{resp.message}"
    end

    # Gets an encaspulated definition of fields, dynamic fields, and field types
    # defined in the schema for a given core or collection
    # ```json
    #   { "types: [ {}, ___ ], "fields": [ {}, ____], dynamicFields", [ {}, ___] }
    #  ```
    #  The attributes of the objects inside each array correspond to the attributes of the
    #  relevant XML element from the Solr `schema.xml`  Note that this
    #  definition leaves out a lot of details (embedded objects) for field types, so
    #  this method does not yield a 1:1 correspondence.
    # @param cname [String] the name of the core or collection
    # @return [Hash] a summary of the fields, dynamic fields, and field
    # types defined in the schema.
    def get_fields(cname)
      schema = get_schema(cname, 'schema.xml')
      doc = Nokogiri::XML(schema)
      fieldTypes = doc.xpath('//fieldType/@name').collect(&:value)
      fields = doc.xpath('//field').collect do |f|
        attrs = f.attributes
        { name: attrs['name'].value, type: attrs['type'].value }
      end
      dynamics = doc.xpath('//dynamicField').collect do |f|
        attrs = f.attributes
        { name: attrs['name'].value, type: attrs['type'].value }
      end

      { types: fieldTypes, fields: fields, dynamicFields: dynamics }
    end

    # Gets the schema.xml format for a core or collection
    # @param cname [String] the name of the core or collection
    # @param format ['json', 'xml', 'schema.xml'] the desired format
    def show_schema(cname, format = 'schema.xml')
      schema = get_schema(cname, format)
      if format.end_with?('xml')
        doc = Nokogiri::XML(schema, &:noblanks)
        puts doc.to_xml(indent: 2)
      else
        puts schema
      end
    end

    def harmonize_schema(cname, schema_config)
      schema = Schema.new(self, cname)
      differ = schema.create_differ(schema_config)
      schema.harmonize
    end

    # Checks whether a named collection exists.
    # @param cname [String] the name of the core or collection
    # @return [true,false]
    def collection_exists?(name)
      get_collections.include?(name)
    end

    # Creates a collection on the server
    # @param name [String] the name of the collection to be created
    # @param config_set [String] the name of an *already existing* config set on the solr server
    #     to use as a base for the new collection.
    # @return [true,false] whether the creation succeded
    def create_collection(name, config_set = 'basic_configs')
      args = ['create_collection', '-c', name, '-d', config_set]
      begin
        create_line = Cocaine::CommandLine.new(@solr_cmd, ':args')
        create_line.run(args: args)
        true
      rescue Cocaine::ExitStatusError => e
        SolrTasks.logger.error e
        false
      end
    end

    # Deletes a collection
    # @param name [String] the name of the collection to be removed
    # @param delete_config [true,false] whether to remove the configuration associated with
    #    the collection; see the documentation of the `-deleteConfig` parameter on the Solr binary
    #     for more information
    #  @return [true,false]
    def delete_collection(name, delete_config = true)
      args = ['delete', '-c', name, '-p', server.port, '-deleteConfig', delete_config.to_s]
      begin
        delete_line = Cocaine::CommandLine.new(@solr_cmd, ':args')
        create_line.run(args: args)
        true
      rescue Cocaine::ExitStatusError => e
        SolrTasks.logger.error e
        false
      end
    end

    # creates a core with a specified name, using a *pre-existing* instance
    # directory (e.g. configuration)
    # @param core_name [String] the name of the core
    # @param instance_dir [String] the path to a directory containing a suitable
    #   Solr core definition (solrconfig, schema, etc.)
    def create_core(core_name, instance_dir = 'solr/conf')
      uri = admin_uri('cores')
      uri.query = URI.encode_www_form(
        action: 'CREATE',
        name: core_name,
        instanceDir: File.expand_path(instance_dir),
        dataDir: '../data'
      )
      res = Net::HTTP.get_response(uri)
      unless res.is_a?(Net::HTTPSuccess)
        SolrTasks.logger.error "Core creation failed, code was #{res.code} : #{res.message}"
        SolrTasks.logger.error "Response body: #{res.body}"
        return false
      end
      true
    end

    # Calls 'commit' on the relevant core or collection
    # @param core_or_collection [String] the name of the core or collection
    # @return [true,false]
    def commit(core_or_collection)
      core_or_collection += '/' unless core_or_collection.end_with?('/')
      uri = URI.join(@base_uri, core_or_collection, 'update')
      uri.query = 'commit=true'
      res = Net::HTTP.get_response(uri)
      res.is_a?(Net::HTTPSuccess)
    end

    # Deletes the specified core.
    # @param core_name [String] the name of the core to be removed
    # @return [true,false]
    def delete_core(core_name)
      uri = admin_uri('cores')
      uri.query = URI.encode_www_form(
        action: 'UNLOAD',
        core: core_name
      )
      res = Net::HTTP.get_response(uri)
      unless res.is_a?(Net::HTTPSuccess)
        SolrTasks.logger.error "Core delete (unload) failed, code was #{res.code} : #{res.message}"
        SolrTasks.logger.error 'Response body:'
        SolrTasks.logger.error res.body
        return false
      end
      true
    end

    # Starts the server, if it's not already running
    # Note that we always start in 'cloud' mode, so collections etc. are available
    # @return [true,false] whether the server is running after the command completes.
    def start
      return true if is_running?
      unless @local
        @logger.warn 'Attempt to call start on remote Solr'
        return true
      end

      begin
        start_line = Cocaine::CommandLine.new(
          @solr_cmd,
          ':args'
        )
        start_line.run(args: ['start', '-c', '-p', @port])
        SolrTasks.logger.info "Started solr on port #{@port}"
      rescue Cocaine::ExitStatusError => e
        SolrTasks.logger.error e
        false
      end
      true
    end

    # issues a 'stop' command to the server
    # @return [true,false] whether the command succeeded
    def stop
      return false unless @local
      begin
        stop_line = Cocaine::CommandLine.new(@solr_cmd, ':args')
        stop_line.run(args: ['stop', '-p', @port])
        true
      rescue Cocaine::ExitStatusError => e
        SolrTasks.logger.error e
        false
      end
    end

    private

    def admin_uri(admin_type = 'collections')
      URI.join(@base_uri, 'admin/', admin_type)
    end
  end
end # module

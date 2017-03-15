require 'rubygems'
require 'rubygems/package'
require 'fileutils'
require 'zlib'
require 'nokogiri'
require 'json'
require 'net/http'
require 'net/https'
require 'open-uri'
require 'uri'
require 'digest/sha1'
require 'cocaine'
require 'yaml'
require 'logger'

module SolrTasks

    class << self
        attr_accessor :logger
    end
    self.logger = Logger.new(STDOUT)


    DEFAULT_CONFIG  = { 
        :version => '6.3.0',
        :uri_base => 'http://localhost:8983/solr/' ,
        :install_base => File.expand_path( './solr-versions/'),
    }

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
        attr_reader :solr_cmd, :config

        # Loads a new instance with configuration taken from a file in YAML format.  See
        # 
        def self.from_file(config_file,environment=nil)
            raise "File #{config_file} does not exist"  unless File.exist?(config_file) 
            config = File.open(config_file) do |f|
                YAML.load(f)
            end
            config = config[environment] if environment
            logger.warn "configuration section '#{environment} not found in YAML file" unless config
            Server.new(config)
        end

        # Creates a new instance
        # @param options [Hash] the options hash.  iIf empty, DEFAULT_OPTIONS will be used.
        # @option options [String] :uri_base the base URI to the solr instance (usually ends with `/solr`), including the hostname
        #               and protocol (http/https). (the `port` attribute will be computed from this)
        # @option options [String] :version the Solr version we are working with.
        # @option options [String] :install_base the base directory for downloaded servers, binaries, etc.  `:install_dir` 
        #               will be set to `@install_base/solr-@version` unless the :install_dir option is provided.
        # @option options [String] :install_dir the full path to an unpacked Solr directory (optional if :install-base is set) 
        # 
        # @see Fetcher
        # @see Extractor 
        def initialize(options={})
            defaults = Marshal.load(Marshal.dump(DEFAULT_CONFIG))
            # merge in any passed in options over defaults, converting keys to symbols
            @config = Hash[ defaults.merge(options).map {|(k,v)| [k.to_sym, v] } ]
            uri_base = @config[:uri_base]
            uri_base += '/' unless uri_base.end_with?('/')
            @base_uri = URI(uri_base)
            @port = @base_uri.port
            @version = @config[:version]
            @install_dir =  options[:install_dir] || File.absolute_path(@config[:install_base])
            @instance_dir = File.join(@install_dir, "solr-#{@version}/")
            @solr_cmd = File.join(@instance_dir, "bin/solr")
            @config.update({ :install_dir => @install_dir, :solr_cmd => @solr_cmd, :port => @port, :version => @version })
            Cocaine::CommandLine.logger = Logger.new(logger) if @config[:verbose]
            @logger = options[:logger] || SolrTasks.logger
        end

        # Checks whether the server is running
        # Note this requires that the 'lsof' utility be installed.  This only works on *nix
        # systems.
        def is_running?            
            line = Cocaine::CommandLine.new(
                "lsof -i",  ":portspec", expected_outcodes: [0,1]
            )
            begin
                output = line.run(portspec: ":#{@port}")
                # lsof has output if something's holding the port open
                return output.length > 0
            rescue Cocaine::ExitStatusError => e
                @logger.error "Unable to execute #{line} : #{e.message}"
                exit 1
            end
        end

        # Get the names of all cores in the Solr instance
        # @return [Array<String>]
        def get_cores
            uri = admin_uri("cores")
            uri.query = 'action=LIST&wt=json'
            res = Net::HTTP.get_response(uri)
            if res.is_a?(Net::HTTPSuccess)
                data = JSON.parse(res.body)
                return data.has_key?('cores') ? data['cores'] : []
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
                return data.has_key?('collections') ? data['collections'] : []
            else
                SolrTasks.logger.error res.body
                exit 1
            end
        end

        # Get the schema for a given core or collection
        # @param cname [String] the name of the core or collection
        # @param ['json', 'xml', 'schema.xml'] the format for the schema document
        # @return [String] the content of the schema
        def get_schema(cname,format)
             uri = URI.join(@base_uri, "#{cname}/schema")
             uri.query = "wt=#{format}"
             resp = Net::HTTP::get_response(uri)
             return resp.body if resp.is_a?(Net::HTTPSuccess)
             @logger.warn "Unexpected response body: \n\n\n#{resp.body}\n\n------\n"
             raise "Schema fetch failed: #{resp.status} : #{resp.message}"
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
            fieldTypes = doc.xpath("//fieldType/@name").collect { |ft| ft.value }
            fields = doc.xpath("//field").collect { |f|
                attrs = f.attributes
                { :name => attrs['name'].value, :type => attrs['type'].value }
            }
            dynamics = doc.xpath('//dynamicField').collect { |f|
                attrs = f.attributes
                { :name => attrs['name'].value, :type => attrs['type'].value }
            }

            { :types => fieldTypes, :fields => fields, :dynamicFields => dynamics }
        end

        # Gets the schema.xml format for a core or collection
        # @param cname [String] the name of the core or collection
        # @param format ['json', 'xml', 'schema.xml'] the desired format
        def show_schema(cname,format='schema.xml')
            schema = get_schema(cname,format)
            if format.end_with?('xml')
                doc = Nokogiri::XML(schema,&:noblanks)
                puts doc.to_xml( indent: 2)
            else
                puts schema
            end
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
        def create_collection(name,config_set="basic_configs")
            args=['create_collection','-c',name,'-d',config_set]
            begin
                create_line = Cocaine::CommandLine.new(@solr_cmd,":args")
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
            args = [ 'delete', '-c', name, '-p', server.port , '-deleteConfig', delete_config.to_s ]
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
        def create_core(core_name, instance_dir='solr/conf')
            uri = admin_uri('cores')
            uri.query = URI.encode_www_form(
                :action => "CREATE",
                :name => core_name,
                :instanceDir => File.expand_path(instance_dir),
                :dataDir => '../data'
            )
            res = Net::HTTP.get_response(uri)
            if not res.is_a?(Net::HTTPSuccess)
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
             uri.query = "commit=true"
             res = Net::HTTP.get_response(uri)
             return res.is_a?(Net::HTTPSuccess)
        end
        
        # Deletes the specified core.
        # @param core_name [String] the name of the core to be removed
        # @return [true,false]
        def delete_core(core_name)
            uri = admin_uri('cores')
            uri.query = URI.encode_www_form(
                :action => "UNLOAD",
                :core => core_name,
            )
            res = Net::HTTP.get_response(uri)
            if not res.is_a?(Net::HTTPSuccess)
                SolrTasks.logger.error "Core delete (unload) failed, code was #{res.code} : #{res.message}"
                SolrTasks.logger.error "Response body:"
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
            begin
                start_line = Cocaine::CommandLine.new(
                    @solr_cmd,
                    ":args")
                start_line.run( args: [ 'start', '-c', '-p', @port ])
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
            begin 
                stop_line = Cocaine::CommandLine.new(@solr_cmd,':args')
                stop_line.run(args: ["stop", "-p", @port ])
                true
            rescue Cocaine::ExitStatusError => e
                SolrTasks.logger.error e
                false
            end
        end

        private

        def admin_uri(admin_type='collections')
            URI.join(@base_uri, 'admin/', admin_type)
        end

    end
    
    # Extracts a Solr serverr from a 'tarball' (`.tar.gz` or `.tgz` file)
    # @!attribute source  [rw]
    #   @return [String] the source file (tarball) to be extracted
    # @!attribute dest [rw]
    #   @return [String] the destination directory for extracted files 
    class Extractor

        attr_accessor :source, :dest

        # GNU tar constant to help handling long file names
        @@TAR_LONGLINK = '././@LongLink'

        # @param source [String]  the source (tarball) file to extract
        # @param dest [String] the destination directory for extracted files.
        def initialize(source, dest)
            @source = source
            @dest = dest
        end

        # Extracts the source file to the destination directory.
        # This will overwrite any files already in the destination!
        def extract
            dest = nil
            SolrTasks.logger.info "Extracting #{@source} to #{@dest}"
            Gem::Package::TarReader.new(Zlib::GzipReader.open(@source)) do
                   |tar|
                tar.each do |entry|
                    if entry.full_name == @@TAR_LONGLINK
                        dest = File.join(@dest,entry.read.strip) 
                        next
                    end
                    dest ||= File.join(@dest, entry.full_name)

                    if entry.directory?
                        FileUtils.rm_rf dest unless File.directory? dest
                        FileUtils.mkdir_p dest, :mode =>entry.header.mode, :verbose => false
                    elsif entry.file?
                        FileUtils.rm_rf dest unless File.file? dest
                        dirname = File.dirname dest
                        FileUtils.mkdir_p dirname unless File.directory? dirname
                        File.open dest, "wb" do |f|
                            f.print entry.read
                        end
                        FileUtils.chmod entry.header.mode, dest, :verbose => false
                    elsif entry.header.typeflag == '2'
                        File.symlink entry.header.linkname, dest
                    end
                    dest = nil
                end # tar.entry
            end # tar.read
        end # method
    end
                
    # Fetches and verifies download of a Solr tarball from Apache servers,
    # in part by parsing the HTML of the 'mirrors' page
    # @!attribute cache_dir [rw]
    #   @return [String] the directory where downloaded files will be cached.
    # @!attribute output_dir [rw]
    #   @return [String] the parent directory for installed Solr servers
    # @!attribute version [rw]
    #   @return [String] the Solr version number
    # @!!attribute sha_uri [r]
    #   @return [Sttring] the (computed) URI to the SHA-1 hash for the downloaded
    #      Solr version (always points at primary Apache download site)
    #  @!attribute mirror_uri [4]
    #    @return [String] (computed) the URI to the requested Solr tarball on a mirror site
    #  @!attribute target [rw]
    #     @return [String] the full path to the downloaded Solr installation file
    #   @!attribute install_dir [rw]
    #     @return the full path to the directory where the server is installed.  Defaults
    #         to "#{output_dir}/solr-#{version}"
    class Fetcher

        MIRROR_BASE = "https://www.apache.org/dyn/closer.lua/lucene/solr/%{version}?as_json=1"

        SHA_BASE = "https://archive.apache.org/dist/lucene/solr/%{version}/solr-%{version}.tgz.sha1"

        attr_accessor :cache_dir, :version, :target, :install_dir

        attr_reader :sha_uri, :mirror_uri

        # Initializes an instance, with a specified installation parent directory, Solr version, and
        # path to cache downloaded files
        # @param output_dir [String] the directory where the solr distribution will be unpacked
        # @param version [String] the Solr version to be requested.
        # @param cache_dir [String] path where downloaded Solr tarballs will be stored.
        def initialize(output_dir,version='6.3.0',cache_dir=File.expand_path('.solrtasks', '~'))
            @cache_dir = cache_dir
            @output_dir = output_dir
            raise "Cannot cache files in directory #{cache_dir} -- it is a regular file" if File.file?(cache_dir)

            if not File.directory?(cache_dir)
                SolrTasks.logger.info "Creating cache for solr downloads in #{cache_dir}"
                FileUtils.mkdir_p(cache_dir)
            end
            filename = "solr-#{version}.tgz"
            @version = version
            @sha_uri = URI(SHA_BASE % {version:version})
            @mirror_uri = URI(MIRROR_BASE % {version:version})
            @target = File.join(cache_dir,filename)
            @install_dir = File.join(output_dir, "solr-#{version}")
        end

        def get_download_uri
            @download_uri ||= fetch_download_uri
        end

        # fetches the Solr tarball from the server, if necessary,
        # and verifies the download
        def fetch
            if not File.size? @target
                fetch_uri = get_download_uri
                raise "Cannot find mirror for Solr #{@version}.  Sorry" unless fetch_uri
                SolrTasks.logger.info "Fetching Solr #{@version} from #{fetch_uri}"
                File.open(@target,'w') do |f|
                    IO.copy_stream( open(fetch_uri),f )
                end
            else
                SolrTasks.logger.info "Solr #{@version} already downloaded to #{@target}"
            end
            if not verify
                SolrTasks.logger.error "Checksums don't match.  Not unpacking"
                exit 1
            else
                SolrTasks.logger.info "SHA-1 checksum looks good."
            end
        end

        def installed?
            File.exists? File.join(@install_dir, 'bin/solr')
        end

        def unpack
            SolrTasks.logger.info "Unpacking Solr #{version} to #{@output_dir}"
            e = Extractor.new(@target,@output_dir)
            if not File.directory? @output_dir
                FileUtils.mkdir_p @output_dir
            end
            e.extract
        end

        def install
            if not installed?
                SolrTasks.logger.info "Solr #{@version} not found.   installing"
                fetch
                verify
                unpack
            end
        end

        def verify
            sha_file = "#{@target}.sha1"
            if not File.exists? sha_file or not File.size? sha_file
                sha_value = Net::HTTP.get(@sha_uri).split(' ').first
                File.open(sha_file,"w") do |f|
                    f.write sha_value
                end
            else
                File.open(sha_file) do |f|
                    sha_value = f.read
                end
            end
            if not File.exists? @target
                SolrTasks.logger.error "Can't verify file.  Call fetch first"
                exit 1
            end
            actual_sha = Digest::SHA1.file(@target).hexdigest()
            raise "Checksum of downloaded file #{@target} does not match" unless actual_sha == sha_value
            true
        end 

        private

        # closest mirror doesn't always have what we want, especially if it's
        # an older version.  Let's give ourselves a fighting chance!
        def find_best_mirrors(count=3)
            paths = [] 
            data = {}
            open(@mirror_uri) do |json_data|
                data = JSON.load(json_data)
                servers = [ data['preferred'], data['http'] ] .flatten[0..count-1]
                paths = servers.collect { |s| URI.join(s, data['path_info']+'/') }
            end
            # add the primary US site as a LAST resort ...
            paths << URI.join( data['backup'][1], data['path_info']+'/' )
        end

        def fetch_download_uri 
            SolrTasks.logger.debug "Finding download location for '#{@version}' from #{@mirror_uri}"
            paths = find_best_mirrors
            SolrTasks.logger.debug "Will check #{paths}"
            candidates = paths.map do |path|
                SolrTasks.logger.debug "trying #{path}"
                resp = Net::HTTP.get_response(path)
                if resp.is_a?(Net::HTTPSuccess)
                    dl_page = Nokogiri::HTML(resp.body)
                    puts dl_page
                    dl_path = dl_page.css("a").select {
                        |link|
                        link['href'] =~ /solr-#{@version}.tgz/
                    }[0]['href']
                    URI.join(path,dl_path)
                end
            end.lazy.first 
            candidates
        end
    end # class
end #module

# frozen_string_literal: true

require 'uri'
require 'net/http'

module SolrTasks
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
    MIRROR_BASE = 'https://www.apache.org/dyn/closer.lua/lucene/solr/%{version}?as_json=1'

    SHA_BASE = 'https://archive.apache.org/dist/lucene/solr/%{version}/solr-%{version}.tgz'

    attr_accessor :cache_dir, :version, :target, :install_dir

    attr_reader :sha_uri, :mirror_uri

    # Initializes an instance, with a specified installation parent directory, Solr version, and
    # path to cache downloaded files
    # @param output_dir [String] the directory where the solr distribution will be unpacked
    # @param version [String] the Solr version to be requested.
    # @param cache_dir [String] path where downloaded Solr tarballs will be stored.
    def initialize(output_dir = '.', version = '7.7.1', cache_dir = File.expand_path('.solrtasks', '~'))
      @cache_dir = cache_dir
      @output_dir = output_dir
      if File.file?(cache_dir)
        raise StandardError("Cannot cache files in directory #{cache_dir} -- it is a regular file")
      end

      unless File.directory?(cache_dir)
        SolrTasks.logger.info("Creating cache for solr downloads in #{cache_dir}")
        FileUtils.mkdir_p(cache_dir)
      end
      filename = "solr-#{version}.tgz"
      @version = version
      @sha_base = URI(format(SHA_BASE, version: version))
      @mirror_uri = URI(format(MIRROR_BASE, version: version))
      @target = File.join(cache_dir, filename)
      @install_dir = File.join(output_dir, "solr-#{version}")
    end

    def die(msg, status = 1)
      warn(msg)
      exit(status)
    end

    def get_download_uri
      @download_uri ||= fetch_download_uri
    end

    def download
      fetch || die("Unable to fetch Solr #{version}")
      verify || die('Unable to verify checksum')
    end

    # fetches the Solr tarball from the server, if necessary,
    def fetch
      return target if File.size?(target)

      fetch_uri = get_download_uri
      unless fetch_uri
        SolrTask.logger.warn("Cannot find mirror for Solr #{@version}.  Sorry")
        return false
      end

      SolrTasks.logger.debug("Fetching Solr #{@version} from #{fetch_uri}")
      File.open(@target, 'w') do |f|
        IO.copy_stream(open(fetch_uri), f)
      end
      target
    end

    def installed?
      File.exist?(File.join(@install_dir, 'bin/solr'))
    end

    def unpack
      SolrTasks.logger.info "Unpacking Solr #{version} to #{@output_dir}"
      e = Extractor.new(@target, @output_dir)
      FileUtils.mkdir_p @output_dir unless File.directory? @output_dir
      e.extract
    end

    def install
      unless installed?
        SolrTasks.logger.info("Solr #{@version} not found. Installing")
        download
        unpack
      end
      target
    end

    def verify
      %w[sha512 sha1].find do |ext|
        target_hash = find_target_digest_value(ext)

        next false unless target_hash

        computed_hash = Digest.const_get(ext.upcase).file(@target).hexdigest
        if target_hash != computed_hash
          SolrTasks.logger.warn("Checksum: '#{target_hash}' for #{ext} does not match computed value '#{computed_hash}'")
        end
        target_hash == computed_hash
      end
    end

    private

    def find_target_digest_value(ext)
      # filename; used on server and on client
      checksum_file = "#{File.basename(@target)}.#{ext}"
      local_checksum = File.join(@cache_dir, checksum_file)
      uri = URI(@sha_base + checksum_file)
      
      if !File.size?(local_checksum)
        SolrTasks.logger.info("Checking for #{ext} at #{uri}")
        resp = Net::HTTP.get_response(uri)
        case resp
        when Net::HTTPOK
          SolrTasks.logger.info("Writing #{local_checksum}")
          File.open(local_checksum, 'w') { |f| f.write(resp.body.split(' ').first) }
        when Net::HTTPNotFound
          warn("#{ext} checksum not found on remote")
        else
          SolrTasks.logger.warn("Unexpected response from Apache download site: #{resp}")
        end
      end
      return File.read(local_checksum).split.first
    end

    # closest mirror doesn't always have what we want, especially if it's
    # an older version.  Let's give ourselves a fighting chance!
    def find_best_mirrors(count = 3)
      filename = "solr-#{@version}.tgz"
      paths = []
      data = {}
      path_info = ''
      open(@mirror_uri) do |json_data|
        data = JSON.load(json_data)
        servers = [data['preferred'], data['http']] .flatten[0..count - 1]
        path_info = data['path_info'] + '/'
        # force https; we will cull them later
        paths = servers.collect { |s| URI.join(s.gsub(/^http:/, 'https:'), path_info, filename) }
      end
      # add the US backup site as a first last resort ...
      paths << URI.join(data['backup'][1], path_info, filename)
      # add the Archive site as a last last resort ...
      paths << URI.join('https://archive.apache.org/dist/', path_info, filename)
    end

    def fetch_download_uri
      SolrTasks.logger.debug("Finding download location for '#{@version}' from #{@mirror_uri}")
      find_best_mirrors.find do |uri|
        begin
          resp = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 2) do |http|
            #http = Net::HTTP.new(uri.host, uri.port)
            #http.use_ssl = true
        
            SolrTasks.logger.debug("trying #{uri} [#{uri.class}] #{uri.host}, #{uri.port}, => #{uri.path}")
            resp = http.request(Net::HTTP::Head.new(uri.request_uri))
            resp
          end
        rescue StandardError => e 
          SolrTasks.logger.debug("exception encountered fetching mirrors: #{e}")
          false
        end
        SolrTasks.logger.debug("Result for #{uri} is #{resp}")
        resp.is_a?(Net::HTTPSuccess)
      end
    end
  end
end

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
    MIRROR_BASE = 'https://www.apache.org/dyn/closer.lua/lucene/solr/%{version}?as_json=1'.freeze

    SHA_BASE = 'https://archive.apache.org/dist/lucene/solr/%{version}/solr-%{version}.tgz.sha1'.freeze

    attr_accessor :cache_dir, :version, :target, :install_dir

    attr_reader :sha_uri, :mirror_uri

    # Initializes an instance, with a specified installation parent directory, Solr version, and
    # path to cache downloaded files
    # @param output_dir [String] the directory where the solr distribution will be unpacked
    # @param version [String] the Solr version to be requested.
    # @param cache_dir [String] path where downloaded Solr tarballs will be stored.
    def initialize(output_dir, version = '6.3.0', cache_dir = File.expand_path('.solrtasks', '~'))
      @cache_dir = cache_dir
      @output_dir = output_dir
      raise "Cannot cache files in directory #{cache_dir} -- it is a regular file" if File.file?(cache_dir)

      unless File.directory?(cache_dir)
        SolrTasks.logger.info "Creating cache for solr downloads in #{cache_dir}"
        FileUtils.mkdir_p(cache_dir)
      end
      filename = "solr-#{version}.tgz"
      @version = version
      @sha_uri = URI(format(SHA_BASE, version: version))
      @mirror_uri = URI(format(MIRROR_BASE, version: version))
      @target = File.join(cache_dir, filename)
      @install_dir = File.join(output_dir, "solr-#{version}")
    end

    def get_download_uri
      @download_uri ||= fetch_download_uri
    end

    # fetches the Solr tarball from the server, if necessary,
    # and verifies the download
    def fetch
      if !File.size? @target
        fetch_uri = get_download_uri
        raise "Cannot find mirror for Solr #{@version}.  Sorry" unless fetch_uri
        SolrTasks.logger.info "Fetching Solr #{@version} from #{fetch_uri}"
        File.open(@target, 'w') do |f|
          IO.copy_stream(open(fetch_uri), f)
        end
      else
        SolrTasks.logger.info "Solr #{@version} already downloaded to #{@target}"
        end
      if !verify
        SolrTasks.logger.error "Checksums don't match.  Not unpacking"
        exit 1
      else
        SolrTasks.logger.info 'SHA-1 checksum looks good.'
      end
    end

    def installed?
      File.exist? File.join(@install_dir, 'bin/solr')
    end

    def unpack
      SolrTasks.logger.info "Unpacking Solr #{version} to #{@output_dir}"
      e = Extractor.new(@target, @output_dir)
      FileUtils.mkdir_p @output_dir unless File.directory? @output_dir
      e.extract
    end

    def install(do_unpack = true)
      unless installed?
        SolrTasks.logger.info "Solr #{@version} not found.   installing"
        fetch
        verify
        unpack if do_unpack
      end
      @target
    end

    def verify
      sha_file = "#{@target}.sha1"
      if (!File.exist? sha_file) || (!File.size? sha_file)
        sha_value = Net::HTTP.get(@sha_uri).split(' ').first
        File.open(sha_file, 'w') do |f|
          f.write sha_value
        end
      else
        File.open(sha_file) do |f|
          sha_value = f.read
        end
      end
      unless File.exist? @target
        SolrTasks.logger.error "Can't verify file.  Call fetch first"
        exit 1
      end
      actual_sha = Digest::SHA1.file(@target).hexdigest
      raise "Checksum of downloaded file #{@target} does not match" unless actual_sha == sha_value
      true
    end

    private

    # closest mirror doesn't always have what we want, especially if it's
    # an older version.  Let's give ourselves a fighting chance!
    def find_best_mirrors(count = 3)
      paths = []
      data = {}
      open(@mirror_uri) do |json_data|
        data = JSON.load(json_data)
        servers = [data['preferred'], data['http']] .flatten[0..count - 1]
        paths = servers.collect { |s| URI.join(s, data['path_info'] + '/') }
      end
      # add the primary US site as a LAST resort ...
      paths << URI.join(data['backup'][1], data['path_info'] + '/')
    end

    def fetch_download_uri
      SolrTasks.logger.debug "Finding download location for '#{@version}' from #{@mirror_uri}"
      paths = find_best_mirrors
      SolrTasks.logger.debug "Will check #{paths}"
      candidates = paths.map do |path|
        SolrTasks.logger.debug "trying #{path}"
        resp = Net::HTTP.get_response(path)
        next unless resp.is_a?(Net::HTTPSuccess)
        dl_page = Nokogiri::HTML(resp.body)
        dl_path = dl_page.css('a').select do |link|
          link['href'] =~ /solr-#{@version}.tgz/
        end[0]['href']
        URI.join(path, dl_path)
      end.lazy.first
      candidates
    end
  end # class
end #module

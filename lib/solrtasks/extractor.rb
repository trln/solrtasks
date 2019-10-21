module SolrTasks
  # Extracts a Solr serverr from a 'tarball' (`.tar.gz` or `.tgz` file)
  # @!attribute source  [rw]
  #   @return [String] the source file (tarball) to be extracted
  # @!attribute dest [rw]
  #   @return [String] the destination directory for extracted files
  class Extractor
    attr_accessor :source, :dest

    # GNU tar constant to help handling long file names
    TAR_LONGLINK = '././@LongLink'.freeze

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
      SolrTasks.logger.debug("Extracting #{@source} to #{@dest}")
      begin
        Gem::Package::TarReader.new(Zlib::GzipReader.open(@source)) do |tar|
          tar.each do |entry|
            if entry.full_name == TAR_LONGLINK
              dest = File.join(@dest, entry.read.strip)
              next
            end
            dest ||= File.join(@dest, entry.full_name)

            if entry.directory?
              FileUtils.rm_rf dest unless File.directory? dest
              FileUtils.mkdir_p dest, mode: entry.header.mode, verbose: false
            elsif entry.file?
              FileUtils.rm_rf dest unless File.file? dest
              dirname = File.dirname dest
              FileUtils.mkdir_p dirname unless File.directory? dirname
              File.open dest, 'wb' do |f|
                f.print entry.read
              end
              FileUtils.chmod entry.header.mode, dest, verbose: false
            elsif entry.header.typeflag == '2'
              File.symlink entry.header.linkname, dest
            end
            dest = nil
          end # tar.entry
        end # tar.read
      rescue StandardError
        SolrTasks.logger.warn("Unable to extract Solr source via native ruby; falling back to native tar")
        `/usr/bin/env tar xzf #{@source} -C #{@dest}`
      end
    end # method
  end
end

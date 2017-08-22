#!/usr/bin/env ruby

require 'rubygems/package'
require 'tempfile'
require 'zlib'

module SolrTasks
  # Allows for repacking a Solr distribution
  # to add extra library files to SOLR_HOME
  # which creates a ready-to-use Solr that includes
  # the extra jars without having to fuss with
  # adding plugins at runtime
  module Repacker
    TAR_LONGLINK = '././@LongLink'.freeze

    def self.generate_filename(_sourcefile); end

    # Re-packs a source Solr .tgz file by adding
    # a set of named library files to  `server/solr/lib`
    def self.add_libraries(source, dest, lib_files)
      temp_dest = Tempfile.new('solr-repack.tar')
      tar_writer = Gem::Package::TarWriter.new(temp_dest)
      solr_home_path = nil
      File.open(source) do |gz|
        Zlib::GzipReader.wrap(gz) do |file|
          Gem::Package::TarReader.new(file) do |tar|
            dest_path = nil
            tar.each do |entry|
              mode = entry.header.mode
              dest_path = entry.read.strip if entry.full_name == TAR_LONGLINK
              dest ||= entry.full_name
              if entry.directory?
                tar_writer.mkdir(entry.full_name, mode)
                if entry.full_name.end_with?('server/solr/')
                  solr_home_path = entry.full_name
                end
              elsif entry.file?
                tar_writer.add_file(entry.full_name, mode) do |new_entry|
                  new_entry.write entry.read
                end
              elsif entry.header.typeflag == '2' # symlink
                # wat?
              end
            end # tar entries
          end # tar reader
        end # gzip wrapper
      end # source file
      lib_files.each do |f|
        next unless File.exist?(f)
        tar_path = File.join(solr_home_path, 'lib', File.basename(f))
        mode = File.stat(f).mode
        tar_writer.add_file(tar_path, mode) do |lib_entry|
          File.open(f, 'rb') { |jar_file| lib_entry.write jar_file.read }
        end
      end
      temp_dest.seek(0)
      Zlib::GzipWriter.wrap(File.open(dest, 'wb')) do |gzw|
        gzw.write(temp_dest.read)
      end
      dest
    end
  end # Repacker module
end

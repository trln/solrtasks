require 'json'
require 'nokogiri'
require 'net/http'
require 'net/https'
require 'uri'
require 'yaml'
require 'logger'

module SolrTasks


    # Represents the schema for a collection on a server.
    class Schema

        attr_accessor :server, :collection

        # Create a new instance for a collection on a server.
        def initialize(server,collection)
            @server = server
            @collection = collection
            @logger = Logger.new STDOUT
        end

        # Get the URI for managing and querying the schema
        # @return [URI]
        def get_schema_uri
            URI.join(@server.base_uri,"#{collection}/schema")
        end

            
        # Gets the schema as a document
        # @param format ['json', 'xml', 'schema.xml']  the format for the schema document
        # @return [String] the content of the schema
        def get(format='json')
            uri = get_schema_uri
            uri.query = "wt=#{format}"
            resp = Net::HTTP::get_response(uri)
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
        def _fields
            schema = get('schema.xml')
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

        def fields 
            @fields ||= _fields
        end

        # Gets the schema.xml format for a core or collection
        # @param cname [String] the name of the core or collection
        # @param format ['json', 'xml', 'schema.xml'] the desired format
        def show(format='schema.xml')
            schema = self.get(collection,format)
            if format.end_with?('xml')
                doc = Nokogiri::XML(schema,&:noblanks)
                puts doc.to_xml( indent: 2)
            else
                puts schema
            end
        end

        def differ
            @differ ||= SchemaDiffer.new
        end

        def create_differ(schema_config)
            @differ = SchemaDiffer.new(self,schema_config)
        end

        def differ=(differ)
            @differ = differ
        end

        def harmonize
            headers = {'Content-Type' => 'application/json'}
            uri = get_schema_uri
            http = Net::HTTP.new(uri.host, uri.port)
            req = Net::HTTP::Post.new(uri.request_uri,headers)
            req.body = @differ.diff
            if @differ.has_diff
                puts req.body
                resp = http.request(req)
                case resp
                when Net::HTTPSuccess
                    puts "Schema updated!"
                else
                    puts "Got #{resp.code}: #{resp.body}"
                end
            else
                puts "Schema is up to date."
            end
        end

    end #Schema

    class SchemaDiffer
        attr_reader :schema, :config, :diff

        def initialize(schema,config_file)
            @schema = schema
            @config = File.open(config_file) { |f| YAML.load(f) }
            @config.delete("_defaults")
        end

        def diff
          @diff ||= request_body
        end

        def has_diff
            diff != '{}'
        end

        def request_body
            fields = schema.fields
            field_names = fields[:fields].map { |f| f[:name] }
            commands = {add_field:[],delete_field:[],replace_field:[]}
            unknown_types = []
            config.each do |fld,cfg|
                next if fld == 'id'
                if not fields[:types].include? cfg['type']
                    unknown__types << "#{fld} has unknown type #{cfg['type']}"
                else
                    field_def = { 'name' => fld,
                                  'type' => cfg['type'],
                                  'indexed' => cfg.fetch('indexed',true),
                                  'stored' => cfg['stored'],
                                  'multiValued' => cfg.fetch('multiValued',false)
                    }

                    if field_names.include?(fld)
                        commands[:replace_field] << field_def
                    else
                        commands[:add_field] << field_def
                    end
                end
            end

            field_names.each do |fld| 
                if not config.include?(fld)
                    commands[:delete_field] << {name: fld} unless fld =~ /^_/
                end
            end

            content = "{"
            commands.each do |cmd_sym,defs| 
                cmd = cmd_sym.to_s.gsub('_','-')
                defs.each do |fd|
                    content << ', ' if content.length > 1
                    content << %["#{cmd}" : #{fd.to_json}] 
                end
            end
            content << '}'
            content
        end

    end
end

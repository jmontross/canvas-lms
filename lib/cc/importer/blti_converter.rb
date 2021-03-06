#
# Copyright (C) 2011 Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.
#
module CC::Importer
  module BLTIConverter
    include CC::Importer
    
    def get_blti_resources
      blti_resources = []

      @manifest.css("resource[type=#{BASIC_LTI}]").each do |r_node|
        res = {}
        res[:migration_id] = r_node['identifier']
        res[:href] = r_node['href']
        res[:files] = []
        r_node.css('file').each do |file_node|
          res[:files] << {:href => file_node[:href]}
        end

        blti_resources << res
      end

      blti_resources
    end

    def convert_blti_links(blti_resources=nil)
      blti_resources ||= get_blti_resources
      tools = []

      blti_resources.each do |res|
        path = res[:href] || res[:files].first[:href]
        path = get_full_path(path)

        if File.exists?(path)
          doc = open_file_xml(path)
          tool = convert_blti_link(doc)
          tool[:migration_id] = res[:migration_id]
          res[:url] = tool[:url] # for the organization item to reference
          
          tools << tool
        end
      end

      tools
    end
    
    def convert_blti_link(doc)
      blti = get_blti_namespace(doc)
      tool = {}
      tool[:description] = get_node_val(doc, "#{blti}|description")
      tool[:title] = get_node_val(doc, "#{blti}|title")
      tool[:url] = get_node_val(doc, "#{blti}|secure_launch_url")
      tool[:url] ||= get_node_val(doc, "#{blti}|launch_url")
      if custom_node = doc.css("#{blti}|custom")
        tool[:custom_fields] = get_custom_properties(custom_node)
      end
      doc.css("#{blti}|extensions").each do |extension|
        tool[:extensions] ||= []
        ext = {}
        ext[:platform] = extension['platform']
        ext[:custom_fields] = get_custom_properties(extension)
        
        if ext[:platform] == CANVAS_PLATFORM
          tool[:privacy_level] = ext[:custom_fields]['privacy_level']
          tool[:domain] = ext[:custom_fields]['domain']
        else
          tool[:extensions] << ext
        end
      end
      tool
    end
    
    def get_custom_properties(node)
      props = {}
      node.children.each do |property|
        next unless property.name == 'property'
        props[property['name']] = property.text
      end
      props
    end
    
    def get_blti_namespace(doc)
      doc.namespaces.each_pair do |key, val|
        if val == BLTI_NAMESPACE
          return key.gsub('xmlns:','')
        end
      end
      "blti"
    end
    
  end
end

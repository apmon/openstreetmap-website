module HttpHelper
  require 'net/http'
  require 'uri'
  require 'xml/libxml'

  # Execute http request
  def self.fetch_text(url)
    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    response = http.request(Net::HTTP::Get.new(uri.request_uri, 
                                               {'Referer' => "http://#{SERVER_URL}", 
                                                'User-Agent' => "Ruby on Rails/OpenStreetMap website-application"}))
    return response.body
  end

  def self.escape_query(query) 
    return URI.escape(query, Regexp.new("[^#{URI::PATTERN::UNRESERVED}]", false, 'N')) 
  end 

  def self.fetch_xml(url) 
    return REXML::Document.new(fetch_text(url)) 
  end 
end

class RoutingController < ApplicationController
  require 'net/http'
  require 'uri'
  require 'xml/libxml'


  # Render start action
  def start
     render :action => "start"
  end


  # Get a kml route
  # 
  def find_route
    # get status of routing service
    if (ROUTING_STATUS === "maintenance")
      # Routing service is in maintenance status. Routes are not calculated at the moment
      @response = "error:maintenance"
      return
    elsif (ROUTING_STATUS === "enabled")
      # Get inputs from request and create a waypoint array from it
      waypoints = Array.new
      params.each do |key, value|
        if (key.to_s[/^wp(\d+)_lat/])
          if waypoints[($1.to_i)-1].nil?
            waypoints[($1.to_i)-1] = { :lat => value }
          else
            waypoints[($1.to_i)-1][:lat] = value
          end
        elsif (key.to_s[/^wp(\d+)_lon/])
          if waypoints[($1.to_i)-1].nil?
            waypoints[($1.to_i)-1] = { :lon => value }
          else
            waypoints[($1.to_i)-1][:lon] = value
          end
        elsif (key.to_s[/^wp(\d+)_display/])
          if waypoints[($1.to_i)-1].nil?
            waypoints[($1.to_i)-1] = { :disp => value }
          else
            waypoints[($1.to_i)-1][:disp] = value
          end
        end
      end
  
      waypoints = validateWaypoints(waypoints)
  
      if(waypoints.length < 2)
        # Giveup if not enough waypoints present
        @response = "error:insufficient_waypoints"
        return
      else    # more than one waypoint present
        #TODO: Split route in several segments
        # during development status: simply delete all but two waypoints
        until (waypoints.length <= 2)
          waypoints.delete_at(waypoints.pop)
        end
  
        @response = route(waypoints)
  
        # Check if route content is not empty
        if(@response =~ /<coordinates><\/coordinates>/)
          @response = "error:no_route_found"
          return
        end
      end
    else
      # Config error in application.yml
      @response = "error:configuration_improperly_formatted" 
      return
    end
      
    #TODO: Respond with kml header
    respond_to do |format|
      format.js
    end
  end


  private

  # Check if all latitude and longitude values are given
  # filter out empty waypoints and not well formed waypoints
  def validateWaypoints(to_validate)
    delete_queue = Array.new
    to_validate.each_with_index do |point_pair, index|
      logger.debug(point_pair.to_s)
      if((point_pair[:lat].empty? || point_pair[:lon].empty?) && !point_pair[:disp].empty?)
        response = fetch_xml("#{NOMINATIM_URL}search?format=xml&q=#{escape_query(point_pair[:disp])}")
        # create result array 
        @results = Array.new 
 
        # extract the results from the response 
        results =  response.elements["searchresults"] 
 
        logger.debug(results)
        # parse the response 
        results.elements.each("place") do |place| 
          point_pair[:lat] = place.attributes["lat"]
          point_pair[:lon] = place.attributes["lon"]
          break
        end
      end
      if(point_pair[:lat].empty? && point_pair[:lon].empty?)
        delete_queue << index
      elsif(point_pair[:lat].empty? || point_pair[:lon].empty?)
        # Waypoint is not well formed: contains not both latitude and longitude value
        delete_queue << index
      elsif(!(point_pair[:lat] =~ /\d+(\.\d+)?/) || !(point_pair[:lon] =~ /\d+(\.\d+)?/))
        # Waypoint has no suitable number format
        delete_queue << index
      end
    end

    # Remove awkward waypoints
    until (delete_queue.empty?)
       to_validate.delete_at(delete_queue.pop)
    end
    delete_queue = nil
    return to_validate
  end

  def json2kml(server_response_s)
    server_response =  ActiveSupport::JSON.decode(server_response_s)

    response = XML::Document.new
    response.encoding = XML::Encoding::UTF_8
    kml = XML::Node.new 'kml'
    response.root = kml
    kml['xmlns'] = "http://www.opengis.net/kml/2.2"
    doc = XML::Node.new 'Document'
    kml << doc
    placemark = XML::Node.new 'Placemark'
    doc << placemark
    geom = XML::Node.new 'GeometryCollection'
    placemark << geom
    line = XML::Node.new 'LineString'
    geom << line
    coordinates = XML::Node.new 'coordinates'
    coord = ""
    server_response["route_geometry"].each do |latLng|
      coord = coord + latLng[1].to_s + "," + latLng[0].to_s + " "
    end
    coordinates << coord
    line << coordinates

    @distance = server_response["route_summary"]["total_distance"]
    if (@distance > 1000)
      @distance = ((@distance / 10) / 100.0).to_s + "km"
    else
      @distance = @distance.to_s + "m"
    end
    @timeNeeded = server_response["route_summary"]["total_time"]
    @timeNeeded = (@timeNeeded / 3600).ceil.to_s + ":" + ("%02d" % ((@timeNeeded / 60).ceil % 60)) + ":" + ("%02d" % (@timeNeeded % 60))

    return response.to_s
  end


  # Decide which routing backend to use
  # simple example for now: fastest car routes by osrm, all the rest by yours
  def route(waypoints)
    if(params[:engine] === "automatic")
      if(params[:means] === "car" && params[:mode] === "fastest")
        @engine = "osrm"
        return osrmRoute(waypoints)
      else
        @engine = "yours"
        return yoursRoute(waypoints)
      end
      #    else
      #      @engine = "mapquest"
      #      return mapquestRoute(waypoints)
      #    end
    elsif (params[:engine] === "osrm")
      @engine = "osrm"
      return osrmRoute(waypoints)
    elsif (params[:engine] === "yours")
      @engine = "yours"
        return yoursRoute(waypoints)
    elsif (params[:engine] === "mapquest")
      @engine = "mapquest"
      return mapquestRoute(waypoints)
    elsif (params[:engine] === "cloudmade")
      @engine = "cloudmade"
      return cloudmadeRoute(waypoints)
    else
    end

  end


  # Get a route calculated via Yours routing service
  def yoursRoute(waypoints)
    querystring = "#{YOURS_URL}"

    # Static values
    querystring += "?format=kml"
    querystring += "&flat=" + waypoints[0][:lat]
    querystring += "&flon=" + waypoints[0][:lon]
    querystring += "&tlat=" + waypoints[1][:lat]
    querystring += "&tlon=" + waypoints[1][:lon]

    # Dynamic values
    if(params[:means] === "bicycle")
       querystring += "&v=bicycle"
    elsif(params[:means] === "feet")
       querystring += "&v=foot"
    end

    if(params[:mode] === "fastest")
       querystring += "&fast=1"
    elsif(params[:mode] === "shortest")
       querystring += "&fast=0"
    end
    
    logger.debug(querystring)

    begin
      response = fetch_text(querystring) 
    rescue Timeout::Error => e
      @response = "error:no_route_found"
      return
    end

    parser = XML::Parser.string(response)
    server_response = parser.parse

    @distance = (server_response.find_first('/kml:kml/kml:Document/kml:distance','kml:http://earth.google.com/kml/2.0').content.to_f * 1000).ceil
    if (@distance > 1000)
      @distance = ((@distance / 10) / 100.0).to_s + "km"
    else
      @distance = @distance.to_s + "m"
    end
    @timeNeeded = "?"

    # Omit busy server
    if(response =~ /Server is busy/i)
      return "error:yours_busy"
    end

    return response.gsub(/\s+/, " ")
  end

   # Get a route calculated via open MapQuest directory service
  def mapquestRoute(waypoints)
    querystring = "http://open.mapquestapi.com/directions/v0/route"

    # Static values
    querystring += "?format=xml"
    querystring += "&from=" + waypoints[0][:lat]
    querystring += "," + waypoints[0][:lon]
    querystring += "&to=" + waypoints[1][:lat]
    querystring += "," + waypoints[1][:lon]

    # Dynamic values
    if(params[:means] === "bicycle")
       querystring += "&routeType=bicycle"
    elsif(params[:means] === "feet")
      querystring += "&routeType=pedestrian"
    elsif(params[:means] == "car")
      if(params[:mode] === "fastest")
        querystring += "&routeType=fastest"
      elsif(params[:mode] === "shortest")
        querystring += "&routeType=shortest"
      end
    end
    querystring += "&generalize=0&shapeFormat=raw&unit=k"

    logger.debug(querystring)

    begin
      server_response_s = fetch_text(querystring) 
    rescue Timeout::Error => e
      @response = "error:no_route_found"
      return
    end

    #Reformat from mapquest specific XML to a kml output

    parser = XML::Parser.string(server_response_s)
    server_response = parser.parse

    response = XML::Document.new
    response.encoding = XML::Encoding::UTF_8
    kml = XML::Node.new 'kml'
    response.root = kml
    kml['xmlns'] = "http://www.opengis.net/kml/2.2"
    doc = XML::Node.new 'Document'
    kml << doc
    placemark = XML::Node.new 'Placemark'
    doc << placemark
    geom = XML::Node.new 'GeometryCollection'
    placemark << geom
    line = XML::Node.new 'LineString'
    geom << line
    coordinates = XML::Node.new 'coordinates'
    coord = ""
    server_response.find('/response/route/shape/shapePoints/latLng').each do |latLng|
      nodes = latLng.children
      coord = coord + nodes[1].content + "," + nodes[0].content + " "
    end
    coordinates << coord
    line << coordinates

    @distance = (server_response.find_first('/response/route/distance').content.to_f*1000).ceil
    if (@distance > 1000)
      @distance = ((@distance / 10) / 100.0).to_s + "km"
    else
      @distance = @distance.to_s + "m"
    end
    @timeNeeded = server_response.find_first('/response/route/formattedTime').content

    return response.to_s
  end

     # Get a route calculated via open MapQuest directory service
  def cloudmadeRoute(waypoints)
    querystring = "http://navigation.cloudmade.com/#{CLOUDMADE_ROUTING_KEY}/api/0.3/"

    # Static values
    querystring += waypoints[0][:lat]
    querystring += "," + waypoints[0][:lon]
    querystring += "," + waypoints[1][:lat]
    querystring += "," + waypoints[1][:lon]

    # Dynamic values
    if(params[:means] === "bicycle")
       querystring += "/bicycle"
    elsif(params[:means] === "feet")
      querystring += "/foot"
    elsif(params[:means] == "car")
      querystring += "/car"
    end
    if(params[:mode] === "fastest")
        querystring += "/fastest.js"
    elsif(params[:mode] === "shortest")
      querystring += "/shortest.js"
    end

    begin
      server_response = fetch_text(querystring) 
    rescue Timeout::Error => e
      @response = "error:no_route_found"
      return
    end
    return json2kml(server_response)
  end


  # Get a route calculated via OSRM routing server
  def osrmRoute(waypoints)
    querystring = "#{OSRM_URL}"
    querystring += "/&output=json&"
    querystring += "&start=" + waypoints[0][:lat]
    querystring += "," + waypoints[0][:lon]
    querystring += "&dest=" + waypoints[1][:lat]
    querystring += "," + waypoints[1][:lon]

    logger.debug(querystring)
    begin
      server_response = fetch_text(querystring) 
    rescue Timeout::Error => e
      @response = "error:no_route_found"
      return
    end
    return json2kml(server_response)
  end


  # Execute http request
  def fetch_text(url)
    return Net::HTTP.get(URI.parse(url))
  end

  # TODO: Dupplicate function from geocoder controller
  def escape_query(query) 
    return URI.escape(query, Regexp.new("[^#{URI::PATTERN::UNRESERVED}]", false, 'N')) 
  end 

  # TODO: Dupplicate function from geocoder controller
  def fetch_xml(url) 
    return REXML::Document.new(fetch_text(url)) 
  end 
end

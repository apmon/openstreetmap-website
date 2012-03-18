require 'osm'

module NotRedactable
  def redacted?
    false
  end

  def redact!
    raise OSM::APICannotRedactError.new
  end
end

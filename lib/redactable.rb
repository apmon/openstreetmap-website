require 'osm'

module Redactable
  def redacted?
    false
  end

  def redact!
    # check that this version isn't the current version
    raise OSM::APICannotRedactError.new if self.is_latest_version?
  end
end

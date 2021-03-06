require 'net/https'
require 'base64'
require 'rexml/document'
require 'hmac-sha1' # this is a gem

class CloudfrontInvalidator  
 BACKOFF_LIMIT = 8192
 BACKOFF_DELAY = 0.025

  def initialize(aws_key, aws_secret, cf_dist_id, options={})
    @aws_key, @aws_secret, @cf_dist_id = aws_key, aws_secret, cf_dist_id

    @api_version = options[:api_version] || '2012-07-01'
  end

  def base_url
    "https://cloudfront.amazonaws.com/#{@api_version}/distribution/"
  end

  def doc_url
    "http://cloudfront.amazonaws.com/doc/#{@api_version}/"
  end

  def invalidate(*keys)
    keys = keys.flatten.map do |k|
      k.start_with?('/') ? k : '/' + k
    end
    
    uri = URI.parse "#{base_url}#{@cf_dist_id}/invalidation"
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    body = xml_body(keys)

    delay = 1
    begin
      resp = http.send_request 'POST', uri.path, body, headers
      doc = REXML::Document.new resp.body
   
      # Create and raise an exception for any error the API returns to us.
      if resp.code.to_i != 201
        error_code = doc.elements["ErrorResponse/Error/Code"][0].to_s
        self.class.const_set(error_code,Class.new(StandardError)) unless self.class.const_defined?(error_code.to_sym)
        raise self.class.const_get(error_code).new(doc.elements["ErrorResponse/Error/Message"])
      end
    
    # Handle the common case of too many in progress by waiting until the others finish.
    rescue TooManyInvalidationsInProgress => e
      sleep delay * BACKOFF_DELAY
      delay *= 2 unless delay >= BACKOFF_LIMIT
      STDERR.puts e.inspect
      retry
    end

    # If we are passed a block, poll on the status of this invalidation with truncated exponential backoff.
    if block_given?
      invalidation_id = doc.elements["Invalidation/Id"][0]
      poll_invalidation(invalidation_id) do |status,time|
        yield status, time
      end
    end
    return resp
  end

  def poll_invalidation(invalidation_id)
    start = Time.now
    delay = 1
    loop do
      doc = REXML::Document.new get_invalidation_detail_xml(invalidation_id)
      status = doc.elements["Invalidation/Status"][0]
      yield status, Time.now - start
      break if status != "InProgress"
      sleep delay * BACKOFF_DELAY
      delay *= 2 unless delay >= BACKOFF_LIMIT
    end
  end

  def list(show_detail = false)
    uri = URI.parse "#{base_url}#{@cf_dist_id}/invalidation"
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    resp = http.send_request 'GET', uri.path, '', headers

    doc = REXML::Document.new resp.body
    puts "MaxItems " + doc.elements["InvalidationList/MaxItems"][0] + "; " + (doc.elements["InvalidationList/MaxItems"][0] == "true" ? "truncated" : "not truncated")

    doc.each_element("/InvalidationList/InvalidationSummary") do |summary|
      invalidation_id = summary.elements["Id"]
      summary_text = "ID " + invalidation_id + ": " + summary.elements["Status"]

      if show_detail
        detail_doc = REXML::Document.new get_invalidation_detail_xml(invalidation_id)
        puts summary_text +
             "; Created at: " +
             detail_doc.elements["Invalidation/CreateTime"].text +
             '; Caller reference: "' +
             detail_doc.elements["Invalidation/InvalidationBatch/CallerReference"].text +
             '"'
        puts ' Invalidated URL paths:'
        
        puts " " + detail_doc.elements.to_a('Invalidation/InvalidationBatch/Path').map { |path| path.text }.join(" ")
      else
        puts summary_text
      end
    end
  end

  def list_detail
    list(true)
  end

  def get_invalidation_detail_xml(invalidation_id)
    uri = URI.parse "#{base_url}#{@cf_dist_id}/invalidation/#{invalidation_id}"
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    resp = http.send_request 'GET', uri.path, '', headers
    return resp.body
  end

  def xml_body(keys)
    xml = <<XML
<?xml version="1.0" encoding="UTF-8"?>
<InvalidationBatch xmlns="#{doc_url}">
<Paths>
<Quantity>#{keys.size}</Quantity>
<Items>
#{keys.map{|k| "<Path>#{k}</Path>" }.join("\n ")}
</Items>
</Paths>
<CallerReference>CloudfrontInvalidator on #{Socket.gethostname} at #{Time.now.to_i}</CallerReference>
</InvalidationBatch>
XML
  end
  
  def headers
    date = Time.now.strftime('%a, %d %b %Y %H:%M:%S %Z')
    digest = HMAC::SHA1.new(@aws_secret)
    digest << date
    signature = Base64.encode64(digest.digest)
    {'Date' => date, 'Authorization' => "AWS #{@aws_key}:#{signature}"}
  end

  class TooManyInvalidationsInProgress < StandardError ; end

end

#!/usr/bin/env ruby

require 'net/http'
require 'timeout'
require 'uri'

JPEG_SOI = "\xFF\xD8".b
JPEG_EOI = "\xFF\xD9".b

class MjpegSmoke
  def initialize(stream_url)
    @uri = URI(stream_url)
  end

  def run
    frame = nil
    content_type = nil

    Timeout.timeout(20) do
      catch(:frame_captured) do
        Net::HTTP.start(@uri.host, @uri.port, open_timeout: 5, read_timeout: 15) do |http|
          request = Net::HTTP::Get.new(@uri)
          http.request(request) do |response|
            assert(response.code.to_i == 200, "MJPEG endpoint should return 200, got #{response.code}")
            content_type = response['content-type'].to_s
            assert(content_type.include?('multipart/x-mixed-replace'), "Unexpected content-type: #{content_type}")

            buffer = +"".b
            response.read_body do |chunk|
              buffer << chunk
              soi_index = buffer.index(JPEG_SOI)
              next if soi_index.nil?

              eoi_index = buffer.index(JPEG_EOI, soi_index + 2)
              next if eoi_index.nil?

              frame = buffer.byteslice(soi_index, eoi_index - soi_index + 2)
              throw :frame_captured
            end
          end
        end
      end
    end

    assert(frame && frame.bytesize > 100, 'MJPEG stream should yield a non-empty JPEG frame')

    puts "MJPEG smoke passed. content-type=#{content_type} frame_bytes=#{frame.bytesize}"
  end

  private

  def assert(condition, message)
    raise message unless condition
  end
end

stream_url = ARGV[0] || 'http://127.0.0.1:9100'
MjpegSmoke.new(stream_url).run

#!/usr/bin/env ruby

require 'base64'
require 'json'
require 'net/http'
require 'timeout'
require 'uri'

JPEG_SOI = "\xFF\xD8".b
JPEG_EOI = "\xFF\xD9".b

class StreamContinuitySmoke
  def initialize(base_url)
    @base_uri = URI(base_url)
  end

  def run
    puts 'Checking /status for MJPEG metadata'
    status = get_json('/status')
    mjpeg_port =
      status.dig('value', 'mjpeg', 'mjpegServerPort') ||
      status.dig('value', 'mjpegServerPort') ||
      9100

    puts 'Creating session'
    session_response = post_json('/session', {
      capabilities: {
        alwaysMatch: {
          bundleId: 'com.apple.Preferences',
          autoLaunch: true,
          shouldWaitForQuiescence: false
        }
      }
    })

    session_id = session_response['sessionId']
    assert(session_id && !session_id.empty?, 'sessionId should be returned from POST /session')

    puts 'Applying MJPEG-friendly settings'
    settings = post_json("/session/#{session_id}/appium/settings", {
      settings: {
        mjpegServerFramerate: 5,
        mjpegServerScreenshootQuality: 20,
        mjpegScalingFactor: 60,
        waitForQuiescence: false,
        animationWait: 0
      }
    })
    assert(settings.dig('value', 'mjpegServerFramerate') == 5, 'MJPEG framerate should update without recreating the session')

    puts 'Reading one MJPEG frame while session is active'
    frame_size = read_mjpeg_frame(mjpeg_port)
    assert(frame_size > 100, 'MJPEG stream should provide a non-empty frame')

    puts 'Re-checking active session after MJPEG consumption'
    session_info = get_json("/session/#{session_id}")
    assert(session_info.dig('value', 'id') == session_id, 'Session should remain active after MJPEG frame consumption')

    window_rect = get_json("/session/#{session_id}/window/rect")
    assert(window_rect.dig('value', 'width').to_f > 0, 'Window rect should still be readable after MJPEG streaming')

    active_app = get_json('/wda/activeAppInfo')
    assert(active_app.dig('value', 'bundleId') == 'com.apple.Preferences', 'Foreground app should stay stable during MJPEG fallback checks')

    screenshot = get_json('/screenshot')
    assert(Base64.decode64(screenshot['value']).bytesize > 100, 'Screenshot should still work after MJPEG frame consumption')

    puts 'Deleting session'
    delete_json("/session/#{session_id}")

    puts "Stream continuity smoke passed. mjpeg_port=#{mjpeg_port} frame_bytes=#{frame_size}"
  end

  private

  def read_mjpeg_frame(port)
    uri = URI("http://#{@base_uri.host}:#{port}")
    frame = nil

    Timeout.timeout(20) do
      catch(:frame_captured) do
        Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 15) do |http|
          request = Net::HTTP::Get.new(uri)
          http.request(request) do |response|
            assert(response.code.to_i == 200, "MJPEG endpoint should return 200, got #{response.code}")

            content_type = response['content-type'].to_s
            assert(content_type.include?('multipart/x-mixed-replace'), "Unexpected MJPEG content-type: #{content_type}")

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

    frame&.bytesize || 0
  end

  def get_json(path)
    response = request(Net::HTTP::Get, path)
    parse_json(response, path)
  end

  def post_json(path, payload)
    response = request(Net::HTTP::Post, path, payload)
    parse_json(response, path)
  end

  def delete_json(path)
    response = request(Net::HTTP::Delete, path)
    parse_json(response, path)
  end

  def request(klass, path, payload = nil)
    uri = @base_uri + path
    Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 30) do |http|
      request = klass.new(uri)
      if payload
        request['Content-Type'] = 'application/json'
        request.body = JSON.generate(payload)
      end
      http.request(request)
    end
  end

  def parse_json(response, path)
    assert(response.code.to_i == 200, "#{path} should return 200, got #{response.code}")
    JSON.parse(response.body)
  rescue JSON::ParserError => e
    raise "#{path} returned invalid JSON: #{e.message}\n#{response.body}"
  end

  def assert(condition, message)
    raise message unless condition
  end
end

base_url = ARGV[0] || 'http://127.0.0.1:8100'
StreamContinuitySmoke.new(base_url).run

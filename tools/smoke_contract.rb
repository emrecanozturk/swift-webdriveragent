#!/usr/bin/env ruby

require 'base64'
require 'json'
require 'net/http'
require 'uri'

STDOUT.sync = true

class SmokeContract
  def initialize(base_url)
    @base_uri = URI(base_url)
  end

  def run
    puts 'Checking /status'
    status = get_json('/status')
    assert(status['value']['ready'] == true, '/status ready should be true')

    puts 'Checking /wda/healthcheck'
    health = get_json('/wda/healthcheck')
    assert(health['value']['xcuitestResponsive'] == true, '/wda/healthcheck should confirm XCTest responsiveness')

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

    puts 'Checking /session/:id'
    session_info = get_json("/session/#{session_id}")
    assert(session_info['value']['id'] == session_id, 'GET /session/:id should return the active session')

    puts 'Applying settings'
    settings = post_json("/session/#{session_id}/appium/settings", {
      settings: {
        snapshotMaxDepth: 4,
        defaultAlertAction: 'accept'
      }
    })
    assert(settings['value']['snapshotMaxDepth'] == 4, 'POST /appium/settings should apply snapshotMaxDepth')

    puts 'Checking active app'
    active_app = get_json('/wda/activeAppInfo')
    assert(active_app.dig('value', 'bundleId') == 'com.apple.Preferences', '/wda/activeAppInfo should reflect the launched app')

    puts 'Checking window metrics'
    screen = get_json('/wda/screen')
    assert(screen['value']['width'].to_f > 0, '/wda/screen width should be positive')

    window_size = get_json("/session/#{session_id}/window/size")
    assert(window_size['value']['height'].to_f > 0, '/window/size height should be positive')

    window_rect = get_json("/session/#{session_id}/window/rect")
    assert(window_rect['value']['width'].to_f > 0, '/window/rect width should be positive')

    puts 'Checking /source?format=json'
    source = get_json('/source?format=json')
    assert(source['value']['type'] == 'Application', '/source?format=json should return an Application root')

    puts 'Checking /screenshot'
    screenshot = get_json('/screenshot')
    assert(Base64.decode64(screenshot['value']).bytesize > 100, '/screenshot should contain a non-empty PNG payload')

    puts 'Checking /metrics'
    metrics = get_text('/metrics')
    assert(metrics.include?('swiftwda_requests_total'), '/metrics should expose Prometheus counters')

    location_support = status.dig('value', 'diagnostics', 'locationSimulation', 'supported')
    if location_support
      puts 'Checking /wda/simulatedLocation'
      initial_location = get_json('/wda/simulatedLocation')
      assert(initial_location['value'].is_a?(Hash), '/wda/simulatedLocation should return a payload object')

      target_location = { latitude: 37.7749, longitude: -122.4194, altitude: 12.5 }
      applied_location = post_json('/wda/simulatedLocation', target_location)
      assert((applied_location.dig('value', 'latitude').to_f - target_location[:latitude]).abs < 0.001, 'POST /wda/simulatedLocation should echo the applied latitude')
      assert((applied_location.dig('value', 'longitude').to_f - target_location[:longitude]).abs < 0.001, 'POST /wda/simulatedLocation should echo the applied longitude')

      fetched_location = get_json('/wda/simulatedLocation')
      assert((fetched_location.dig('value', 'latitude').to_f - target_location[:latitude]).abs < 0.001, 'GET /wda/simulatedLocation should return the simulated latitude')
      assert((fetched_location.dig('value', 'longitude').to_f - target_location[:longitude]).abs < 0.001, 'GET /wda/simulatedLocation should return the simulated longitude')

      delete_json('/wda/simulatedLocation')
      cleared_location = get_json('/wda/simulatedLocation')
      assert(cleared_location.dig('value', 'latitude').nil?, 'DELETE /wda/simulatedLocation should clear the cached latitude')
    else
      puts 'Skipping location smoke because the runtime reports no native location simulation support.'
    end

    puts 'Deleting session'
    delete_json("/session/#{session_id}")

    puts 'Smoke contract passed.'
  end

  private

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

  def get_text(path)
    response = request(Net::HTTP::Get, path)
    assert(response.code.to_i == 200, "#{path} should return 200")
    response.body
  end

  def parse_json(response, path)
    assert(response.code.to_i == 200, "#{path} should return 200, got #{response.code}")
    JSON.parse(response.body)
  rescue JSON::ParserError => e
    raise "#{path} returned invalid JSON: #{e.message}\n#{response.body}"
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

  def assert(condition, message)
    raise message unless condition
  end
end

base_url = ARGV[0] || 'http://127.0.0.1:8100'
SmokeContract.new(base_url).run

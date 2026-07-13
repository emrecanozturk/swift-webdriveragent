#!/usr/bin/env ruby
# frozen_string_literal: true

require 'xcodeproj'

ROOT = File.expand_path('..', __dir__)
PROJECT_NAME = 'WebDriverAgent'
PROJECT_PATH = File.join(ROOT, "#{PROJECT_NAME}.xcodeproj")

project = Xcodeproj::Project.new(PROJECT_PATH)
project.root_object.attributes['LastUpgradeCheck'] = '2620'
project.root_object.attributes['TargetAttributes'] ||= {}

app_group = project.main_group.new_group('IntegrationApp', 'IntegrationApp')
runner_group = project.main_group.new_group('WebDriverAgentRunner', 'WebDriverAgentRunner')
tools_group = project.main_group.new_group('tools', 'tools')
tools_group.new_file('generate_project.rb')

app_target = project.new_target(:application, 'IntegrationApp', :ios, '15.0', nil, :swift)
runner_target = project.new_target(:ui_test_bundle, 'WebDriverAgentRunner', :ios, '15.0', nil, :swift)
runner_target.add_dependency(app_target)

project.root_object.attributes['TargetAttributes'][runner_target.uuid] = {
  'TestTargetID' => app_target.uuid,
}

{
  app_target => [
    ['AppDelegate.swift', app_group],
  ],
  runner_target => [
    ['Info.plist', runner_group],
    ['WebDriverAgentRunnerTests.swift', runner_group],
    ['WDATypes.swift', runner_group],
    ['HTTPServer.swift', runner_group],
    ['ElementTree.swift', runner_group],
    ['WDAAgent.swift', runner_group],
  ],
}.each do |target, files|
  files.each do |file_name, group|
    ref = group.new_file(file_name)
    target.source_build_phase.add_file_reference(ref) if file_name.end_with?('.swift')
  end
end

app_target.build_configurations.each do |config|
  config.build_settings['SWIFT_WDA_BUNDLE_PREFIX'] = 'io.github.swiftwda'
  config.build_settings['SWIFT_WDA_DEVELOPMENT_TEAM'] = ''
  config.build_settings['SWIFT_WDA_INTEGRATION_APP_BUNDLE_ID'] = '$(SWIFT_WDA_BUNDLE_PREFIX).IntegrationApp'
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = '$(SWIFT_WDA_INTEGRATION_APP_BUNDLE_ID)'
  config.build_settings['INFOPLIST_FILE'] = 'IntegrationApp/Info.plist'
  config.build_settings['GENERATE_INFOPLIST_FILE'] = 'NO'
  config.build_settings['SWIFT_VERSION'] = '5.0'
  config.build_settings['CODE_SIGN_STYLE'] = 'Automatic'
  config.build_settings['DEVELOPMENT_TEAM'] = '$(SWIFT_WDA_DEVELOPMENT_TEAM)'
  config.build_settings['ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES'] = 'YES'
  config.build_settings['TARGETED_DEVICE_FAMILY'] = '1,2'
  config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
  config.build_settings['SUPPORTED_PLATFORMS'] = 'iphoneos iphonesimulator'
end

runner_target.build_configurations.each do |config|
  config.build_settings['SWIFT_WDA_BUNDLE_PREFIX'] = 'io.github.swiftwda'
  config.build_settings['SWIFT_WDA_DEVELOPMENT_TEAM'] = ''
  config.build_settings['SWIFT_WDA_RUNNER_BUNDLE_ID'] = '$(SWIFT_WDA_BUNDLE_PREFIX).WebDriverAgentRunner'
  config.build_settings['WDA_PRODUCT_BUNDLE_IDENTIFIER'] = '$(SWIFT_WDA_RUNNER_BUNDLE_ID)'
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = '$(SWIFT_WDA_RUNNER_BUNDLE_ID)'
  config.build_settings['INFOPLIST_FILE'] = 'WebDriverAgentRunner/Info.plist'
  config.build_settings['GENERATE_INFOPLIST_FILE'] = 'NO'
  config.build_settings['SWIFT_VERSION'] = '5.0'
  config.build_settings['CODE_SIGN_STYLE'] = 'Automatic'
  config.build_settings['DEVELOPMENT_TEAM'] = '$(SWIFT_WDA_DEVELOPMENT_TEAM)'
  config.build_settings['TEST_TARGET_NAME'] = 'IntegrationApp'
  config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
  config.build_settings['SUPPORTED_PLATFORMS'] = 'iphoneos iphonesimulator'
  config.build_settings['TARGETED_DEVICE_FAMILY'] = '1,2'
  config.build_settings['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/Frameworks', '@loader_path/Frameworks']
end

scheme = Xcodeproj::XCScheme.new
scheme.configure_with_targets(app_target, runner_target)
scheme.set_launch_target(runner_target)
scheme.launch_action.environment_variables = Xcodeproj::XCScheme::EnvironmentVariables.new([
  { key: 'USE_PORT', value: '$(USE_PORT)', enabled: true },
  { key: 'USE_IP', value: '$(USE_IP)', enabled: true },
  { key: 'UPGRADE_TIMESTAMP', value: '$(UPGRADE_TIMESTAMP)', enabled: true },
  { key: 'MJPEG_SERVER_PORT', value: '$(MJPEG_SERVER_PORT)', enabled: true },
  { key: 'WDA_PRODUCT_BUNDLE_IDENTIFIER', value: '$(WDA_PRODUCT_BUNDLE_IDENTIFIER)', enabled: true },
])
scheme.launch_action.buildable_product_runnable = nil
scheme.launch_action.xml_element.delete_element('MacroExpansion')
scheme.launch_action.add_macro_expansion(Xcodeproj::XCScheme::MacroExpansion.new(runner_target))
scheme.profile_action.buildable_product_runnable = nil
scheme.profile_action.xml_element.delete_element('MacroExpansion')
scheme.profile_action.xml_element.add_element(Xcodeproj::XCScheme::MacroExpansion.new(runner_target).xml_element)
scheme.save_as(PROJECT_PATH, 'WebDriverAgentRunner', true)

project.save

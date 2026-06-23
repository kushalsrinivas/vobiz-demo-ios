require 'xcodeproj'
require 'fileutils'

# Paths
project_dir = File.expand_path(File.dirname(__FILE__))
project_path = File.join(project_dir, 'VobizDemo.xcodeproj')
src_dir = File.join(project_dir, 'VobizDemo')

puts "📁 Creating Xcode project at: #{project_path}"

# Remove existing project if it exists to generate cleanly
if Dir.exist?(project_path)
  puts "🧼 Removing existing project..."
  FileUtils.rm_rf(project_path)
end

# Initialize project
project = Xcodeproj::Project.new(project_path)
project.initialize_from_scratch

# Create main group
main_group = project.main_group.new_group('VobizDemo', 'VobizDemo')

# Create iOS target
target = project.new_target(:application, 'VobizDemo', :ios, '15.0', nil, :swift)

# Add source files
swift_files = []
info_plist_ref = nil

Dir.glob(File.join(src_dir, '*')).each do |file_path|
  file_name = File.basename(file_path)
  
  # Create reference
  file_ref = main_group.new_file(file_name)
  
  if file_name.end_with?('.swift')
    swift_files << file_ref
    target.source_build_phase.add_file_reference(file_ref)
  elsif file_name == 'Info.plist'
    info_plist_ref = file_ref
  end
end

# Set target attributes for Automatic Signing using root_object
project.root_object.attributes['TargetAttributes'] ||= {}
project.root_object.attributes['TargetAttributes'][target.uuid] = {
  'ProvisioningStyle' => 'Automatic'
}

# Set build settings
project.targets.each do |t|
  t.build_configurations.each do |config|
    config.build_settings['INFOPLIST_FILE'] = 'VobizDemo/Info.plist'
    config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.fancall.VobizDemo'
    config.build_settings['PRODUCT_NAME'] = 'VobizDemo'
    config.build_settings['SWIFT_VERSION'] = '5.0'
    config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
    config.build_settings['TARGETED_DEVICE_FAMILY'] = '1' # iPhone only
    config.build_settings['SDKROOT'] = 'iphoneos'
    
    # Configure Automatic Developer Code Signing (allows deployment to physical devices like Puter iPhone)
    config.build_settings['CODE_SIGN_STYLE'] = 'Automatic'
    config.build_settings['CODE_SIGN_IDENTITY'] = 'Apple Development'
    config.build_settings['CODE_SIGNING_ALLOWED'] = 'YES'
  end
end

# Save the project
project.save

puts "✅ Xcode project generated successfully with Automatic Code Signing enabled!"

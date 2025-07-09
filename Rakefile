require "bundler/gem_tasks"

Dir.glob(File.join('tasks/**/*.rake')).each { |file| load file }

task default: :spec

begin
  require 'github_changelog_generator/task'
  require_relative 'lib/puppetserver/ca/version'

  GitHubChangelogGenerator::RakeTask.new :changelog do |config|
    config.header = <<~HEADER.chomp
    # Changelog

    All notable changes to this project will be documented in this file.
    HEADER
    config.user = 'openvoxproject'
    config.project = 'openvoxserver-ca'
    config.exclude_labels = %w[dependencies duplicate question invalid wontfix wont-fix modulesync skip-changelog]
    config.future_release = Puppetserver::Ca::VERSION
    config.since_tag = '2.7.0'
  end
rescue LoadError
  task :changelog do
    abort("Run `bundle install --with release` to install the `github_changelog_generator` gem.")
  end
end

desc 'Prepare for a release'
task 'release:prepare' => [:changelog]

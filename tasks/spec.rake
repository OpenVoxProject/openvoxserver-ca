# frozen_string_literal: true

begin
  require 'rspec/core/rake_task'

  desc 'Run rspec test in sequential order'
  RSpec::Core::RakeTask.new(:spec)

  desc 'Run rspec test in random order'
  RSpec::Core::RakeTask.new(:spec_random) do |t|
    t.rspec_opts = '--order random'
  end
rescue LoadError
  puts 'Could not load rspec'
end

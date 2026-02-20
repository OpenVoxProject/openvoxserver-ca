source "https://rubygems.org"

git_source(:github) {|repo_name| "https://github.com/#{repo_name}" }

# Specify your gem's dependencies in puppetserver-ca.gemspec
gemspec

gem 'hocon', '~> 1.2', require: false

group(:release, optional: true) do
  gem 'faraday-retry', require: false
  gem 'github_changelog_generator', require: false
end

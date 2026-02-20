
lib = File.expand_path("../lib", __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "puppetserver/ca/version"

Gem::Specification.new do |spec|
  spec.name          = "openvoxserver-ca"
  spec.version       = Puppetserver::Ca::VERSION
  spec.authors       = ["OpenVox Project"]
  spec.email         = ["openvox@voxpupuli.org"]
  spec.license       = "Apache-2.0"

  spec.summary       = %q{A simple CLI tool for interacting with OpenVox Server's Certificate Authority}
  spec.homepage      = "https://github.com/OpenVoxProject/openvoxserver-ca/"

  spec.files         = `git ls-files -z`.split("\x0").select do |f|
    f.match(%r{^(lib|exe)/|.md$|^LICENSE$})
  end
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_runtime_dependency "openfact", [">= 5.0.0", "< 6"]

  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rspec", "~> 3.4"

  # openvoxserver 7 uses jruby 9.3 which is compatible with MRI ruby 2.6
  spec.required_ruby_version = '>= 2.6.0'
end

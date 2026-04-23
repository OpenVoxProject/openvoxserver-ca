require 'etc'
require 'fileutils'

module Puppetserver
  module Ca
    module Utils
      class FileSystem

        DIR_MODES = {
          :ssldir => 0771,
          :cadir => 0755,
          :certdir => 0755,
          :privatekeydir => 0750,
          :publickeydir => 0755,
          :signeddir => 0755
        }

        def self.write_file(path, one_or_more_objects, mode)
          File.open(path, 'w', mode) do |f|
            Array(one_or_more_objects).each do |object|
              f.puts object.to_s
            end
          end
          ensure_ownership(path)
        end

        def self.ensure_dirs(one_or_more_dirs)
          Array(one_or_more_dirs).each do |directory|
            ensure_dir(directory)
          end
        end

        # Warning: directory mode should be specified in DIR_MODES above
        def self.ensure_dir(directory)
          if !File.exist?(directory)
            FileUtils.mkdir_p(directory, mode: DIR_MODES[directory])
            ensure_ownership(directory)
          end
        end

        def self.validate_file_paths(one_or_more_paths)
          errors = []
          Array(one_or_more_paths).each do |path|
            if !File.exist?(path) || !File.readable?(path)
              errors << "Could not read file '#{path}'"
            end
          end

          errors
        end

        def self.check_for_existing_files(one_or_more_paths)
          errors = []
          Array(one_or_more_paths).each do |path|
            if File.exist?(path)
              errors << "Existing file at '#{path}'"
            end
          end
          errors
        end

        def self.forcibly_symlink(source, link_target)
          FileUtils.remove_dir(link_target, true)
          FileUtils.symlink(source, link_target)
          ensure_ownership(link_target)
        end

        # Chown the path to the puppet user when running as root.
        # Skipped otherwise: a non-root process can only have created the path
        # as itself, so ownership is already correct, and chowning to any other
        # user would require CAP_CHOWN (unavailable in rootless containers).
        #
        # Uses `FileUtils.chown` rather than `File.chown` so that when `path`
        # is a symlink it operates on the link itself rather than its target.
        def self.ensure_ownership(path)
          return unless running_as_root?
          user = pe_puppet_exists? ? 'pe-puppet' : 'puppet'
          group = pe_puppet_exists? ? 'pe-puppet' : 'puppet'
          FileUtils.chown(user, group, path)
        end

        def self.running_as_root?
          !Gem.win_platform? && Process.euid == 0
        end

        def self.pe_puppet_exists?
          !!(Etc.getpwnam('pe-puppet') rescue nil)
        end
      end
    end
  end
end

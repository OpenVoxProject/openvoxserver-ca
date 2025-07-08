require 'optparse'
require 'openssl'
require 'set'
require 'puppetserver/ca/errors'
require 'puppetserver/ca/utils/cli_parsing'
require 'puppetserver/ca/utils/file_system'
require 'puppetserver/ca/utils/config'
require 'puppetserver/ca/x509_loader'
require 'puppetserver/ca/config/puppet'

module Puppetserver
  module Ca
    module Action
      class Prune
        include Puppetserver::Ca::Utils

        SUMMARY = "Prune the local CRL on disk to remove certificate entries"
        BANNER = <<-BANNER
Usage:
  puppetserver ca prune [--help]
  puppetserver ca prune [--config]
  puppetserver ca prune [--config] [--remove-duplicates]
  puppetserver ca prune [--config] [--remove-expired]
  puppetserver ca prune [--config] [--remove-entries] [--serial NUMBER[,NUMBER]] [--certname NAME[,NAME]]

Description:
  Prune the list of revoked certificates. If no options are provided or
  --remove-duplicates is specified, prune CRL of any duplicate entries.
  If --remove-expired is specified, remove expired entries from CRL.
  If --remove-entries is specified, remove matching entries provided by
  --serial and/or --certname values. This command will only prune the CRL
  issued by Puppet's CA cert.

Options:
BANNER

        def initialize(logger)
          @logger = logger
        end

        def run(inputs)
          config_path = inputs['config']
          remove_duplicates = inputs['remove-duplicates']
          remove_expired = inputs['remove-expired']
          remove_entries = inputs['remove-entries']
          serialnumbers = inputs['serial']
          certnames = inputs['certname']
          exit_code = 0

          # Validate the config path.
          if config_path
            errors = FileSystem.validate_file_paths(config_path)
            return 1 if Errors.handle_with_usage(@logger, errors)
          end

          # Validate puppet config setting.
          puppet = Config::Puppet.new(config_path)
          puppet.load(logger: @logger)
          return 1 if Errors.handle_with_usage(@logger, puppet.errors)

          # Validate arguments
          if (remove_entries && (!serialnumbers && !certnames))
            return 1 if Errors.handle_with_usage(@logger,["--remove-entries option require --serial or --certname values"])
          end

          # Validate that we are offline
          return 1 if HttpClient.check_server_online(puppet.settings, @logger)

          # Getting the CRL(s)
          loader = X509Loader.new(puppet.settings[:cacert], puppet.settings[:cakey], puppet.settings[:cacrl])
          inventory_file = puppet.settings[:cert_inventory]
          cadir = puppet.settings[:cadir]

          verified_crls = loader.crls.select { |crl| crl.verify(loader.key) }
          number_of_removed_duplicates = 0
          number_of_removed_crl_entries = 0

          if verified_crls.length == 1
            puppet_crl = verified_crls.first
            @logger.inform("Total number of certificates found in Puppet's CRL is: #{puppet_crl.revoked.length}.")

            if remove_entries
              if serialnumbers
                number_of_removed_crl_entries += prune_using_serial(puppet_crl, loader.key, serialnumbers)
              end
              if certnames
                number_of_removed_crl_entries += prune_using_certname(puppet_crl, loader.key, inventory_file, cadir, certnames)
              end
            end

            if remove_expired
              number_of_removed_crl_entries += prune_expired(puppet_crl, loader.key, inventory_file, cadir)
            end

            if (remove_duplicates || (!remove_entries && !remove_expired))
               number_of_removed_duplicates += prune_CRL(puppet_crl)
            end


            if (number_of_removed_duplicates > 0 || number_of_removed_crl_entries > 0)
              update_pruned_CRL(puppet_crl, loader.key)
              FileSystem.write_file(puppet.settings[:cacrl], loader.crls, 0644)
              @logger.inform("Removed #{number_of_removed_duplicates} duplicated certs from Puppet's CRL.") if number_of_removed_duplicates > 0
              @logger.inform("Removed #{number_of_removed_crl_entries} certs from Puppet's CRL.") if number_of_removed_crl_entries > 0
            else
              @logger.inform("No matching revocations found in the CRL for pruning")
            end
          else
            @logger.err("Could not identify Puppet's CRL. Aborting prune action.")
            exit_code = 1
          end
          return exit_code
        end

        def prune_CRL(crl)
          number_of_removed_duplicates = 0

          existed_serial_number = Set.new()
          revoked_list = crl.revoked
          @logger.debug("Pruning duplicate entries in CRL for issuer " \
            "#{crl.issuer.to_s(OpenSSL::X509::Name::RFC2253)}") if @logger.debug?

          revoked_list.delete_if do |revoked|
            if existed_serial_number.add?(revoked.serial)
              false
            else
              number_of_removed_duplicates += 1
              @logger.debug("Removing duplicate of #{revoked.serial}, " \
                "revoked on #{revoked.time}\n") if @logger.debug?
              true
            end
          end
          crl.revoked=(revoked_list)

          return number_of_removed_duplicates
        end

        def update_pruned_CRL(crl, pkey)
          # Updating extensions in-place does not work with some ruby versions / implementation. Copy & recreate them.
          extensions = crl.extensions
          crl.extensions = []

          ef = OpenSSL::X509::ExtensionFactory.new
          ef.crl = crl

          extensions.each do |ext|
            if ext.oid == "crlNumber"
              if RUBY_ENGINE == "jruby"
                # Creating a crlNumber extension without an ExtensionFactory produce incorrect result on jruby
                crl.add_extension(ef.create_extension("crlNumber", ext.value.next))
              else
                # Creating a crlNumber extension with an ExtensionFactory rais on exception on MRI
                crl.add_extension(OpenSSL::X509::Extension.new("crlNumber", ext.value.next))
              end
            else
              crl.add_extension(ext)
            end
          end

          crl.sign(pkey, OpenSSL::Digest::SHA256.new)
        end

        def prune_using_serial(crl, key, serialnumbers)
          removed_serials = []
          revoked_list = crl.revoked
          @logger.debug("Removing entries in CRL for issuer " \
            "#{crl.issuer.to_s(OpenSSL::X509::Name::RFC2253)}") if @logger.debug?
          serialnumbers.each do |serial|
            if serial.match(/^(?:0[xX])?[A-Fa-f0-9]+$/)
              revoked_list.delete_if do |revoked|
                if revoked.serial == OpenSSL::BN.new(serial.hex)
                  removed_serials.push(serial)
                  true
                end
              end
            end
          end
          crl.revoked = (revoked_list)
          @logger.debug("Removed these CRL entries : #{removed_serials}") if @logger.debug?
          return removed_serials.length
        end

        def prune_using_certname(crl, key, inventory_file, cadir, certnames)
          serialnumbers = []
          @logger.debug("Checking inventory file #{inventory_file} for matching cert names") if @logger.debug?
          errors = FileSystem.validate_file_paths(inventory_file)
          if errors.empty?
            File.open(inventory_file).each_line do |line|
              certnames.each do |certname|
                if line.match(/\/CN=#{certname}$/) && line.split.length == 4
                  serialnumbers.push(line.split.first)
                  certnames.delete(certname)
                end
              end
            end
          else
            @logger.warn "Reading inventory file at #{inventory_file} failed with error #{errors}"
          end
          if certnames
            @logger.debug("Checking CA dir #{cadir} for matching cert names")
            certnames.each do |certname|
              cert_file = "#{cadir}/signed/#{certname}.pem"
              if File.file?(cert_file)
                raw = File.read(cert_file)
                certificate = OpenSSL::X509::Certificate.new(raw)
                serial = certificate.serial
                serialnumbers.push(serial.to_s(16))
              end
            end
            prune_using_serial(crl, key, serialnumbers)
          end
        end

        def prune_expired (crl, key, inventory_file, cadir)
          serialnumbers = []
          signed_dir = "#{cadir}/signed"
          @logger.debug("Checking inventory file #{inventory_file} for expired entries") if @logger.debug?
          errors = FileSystem.validate_file_paths(inventory_file)
          if errors.empty?
            File.open(inventory_file).each_line do |line|
              if line.match(/\/CN=.*$/) && line.split.length == 4
                not_after = line.split[2]
                begin
                  not_after = Time.parse(line.split[2])
                  serialnumbers.push(line.split.first) if not_after < Time.now
                rescue ArgumentError
                  @logger.warn "Invalid not_after time found in inventory.txt file at #{line}"
                  next
                end
              end
            end
          else
            @logger.warn "Reading inventory file at #{inventory_file} failed with error #{errors}"
          end
          @logger.debug("Checking CA dir #{cadir} for expired certs")
          Dir.foreach(signed_dir) do |filename|
            if File.extname(filename) == '.pem'
              raw = File.read("#{signed_dir}/#{filename}")
              certificate = OpenSSL::X509::Certificate.new(raw)
              serialnumbers.push(certificate.serial.to_s(16)) if certificate.not_after < Time.now
            end
          end
          prune_using_serial(crl, key, serialnumbers)
        end

        def self.parser(parsed = {})
          OptionParser.new do |opts|
            opts.banner = BANNER
            opts.on('--help', 'Display this command-specific help output') do |help|
              parsed['help'] = true
            end
            opts.on('--config CONF', 'Path to the puppet.conf file on disk') do |conf|
              parsed['config'] = conf
            end
            opts.on('--remove-duplicates', 'Remove duplicate entries from CRL(default)') do |remove_duplicates|
              parsed['remove-duplicates'] = true
            end
            opts.on('--remove-expired', 'Remove expired  entries from CRL') do |remove_expired|
              parsed['remove-expired'] = true
            end
            opts.on('--remove-entries', 'Remove entries from CRL') do |remove_entries|
              parsed['remove-entries'] = true
            end
            opts.on('--serial NUMBER[,NUMBER]', Array, 'Serial numbers(s) in HEX to be removed from CRL') do |serialnumbers|
              parsed['serial'] = serialnumbers
            end
            opts.on('--certname NAME[,NAME]', Array, 'Name(s) of the cert(s) to be removed from CRL') do |certnames|
              parsed['certname'] = certnames
            end
          end
        end

        def parse(args)
          results = {}
          parser = self.class.parser(results)
          errors = CliParsing.parse_with_errors(parser, args)
          errors_were_handled = Errors.handle_with_usage(@logger, errors, parser.help)

          if errors_were_handled
            exit_code = 1
          else
            exit_code = nil
          end
          return results, exit_code
        end
      end
    end
  end
end

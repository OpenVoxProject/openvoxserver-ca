require 'openssl'

require 'puppetserver/ca/host'
require 'puppetserver/ca/utils/file_system'
require 'puppetserver/ca/x509_loader'

module Puppetserver
  module Ca
    class LocalCertificateAuthority

      # Make the certificate valid as of yesterday, because so many people's
      # clocks are out of sync.  This gives one more day of validity than people
      # might expect, but is better than making every person who has a messed up
      # clock fail, and better than having every cert we generate expire a day
      # before the user expected it to when they asked for "one year".
      CERT_VALID_FROM = (Time.now - (60*60*24)).freeze

      SSL_SERVER_CERT = "serverAuth"
      SSL_CLIENT_CERT = "clientAuth"

      CLI_AUTH_EXT_OID = "1.3.6.1.4.1.34380.1.3.39"

      SERVER_EXTENSIONS = [
        ["basicConstraints", "CA:FALSE", true],
        ["nsComment", "Puppet Server Internal Certificate", false],
        ["authorityKeyIdentifier", "keyid:always", false],
        ["extendedKeyUsage", "#{SSL_SERVER_CERT}, #{SSL_CLIENT_CERT}", true],
        ["keyUsage", "keyEncipherment, digitalSignature", true],
        ["subjectKeyIdentifier", "hash", false]
      ].freeze

      CA_EXTENSIONS = [
        ["basicConstraints", "CA:TRUE", true],
        ["keyUsage", "keyCertSign, cRLSign", true],
        ["subjectKeyIdentifier", "hash", false],
        ["nsComment", "Puppet Server Internal Certificate", false],
        ["authorityKeyIdentifier", "keyid:always", false]
      ].freeze

      attr_reader :cert, :cert_bundle, :key, :crl, :crl_chain

      def initialize(digest, settings)
        @digest = digest
        @host = Host.new(digest)
        @settings = settings
        @errors = []

        if ssl_assets_exist?
          loader = Puppetserver::Ca::X509Loader.new(@settings[:cacert], @settings[:cakey], @settings[:cacrl])
          if loader.errors.empty?
            load_ssl_components(loader)
          else
            @errors += loader.errors
            @errors << "CA not initialized. Please set up your CA before attempting to generate certs offline."
          end
        end
      end

      def ssl_assets_exist?
        File.exist?(@settings[:cacert]) &&
          File.exist?(@settings[:cakey]) &&
          File.exist?(@settings[:cacrl])
      end

      def load_ssl_components(loader)
        @cert_bundle = loader.certs
        @key = loader.key
        @cert = loader.cert
        @crl_chain = loader.crls
        @crl = loader.crl
      end

      # Initialize SSL state
      #
      # This method is similar to {#load_ssl_components}, but has extra
      # logic for initializing components that may not be present when
      # the CA is set up for the first time. For example, SSL components
      # provided by an external CA will often not include a pre-generated
      # leaf CRL.
      #
      # @note Check {#errors} after calling this method for issues that
      #   may have occurred during initialization.
      #
      # @param loader [Puppetserver::Ca::X509Loader]
      # @return [void]
      def initialize_ssl_components(loader)
        @cert_bundle = loader.certs
        @key = loader.key
        @cert = loader.cert

        if loader.crl.nil?
          loader.crl = create_crl_for(@cert, @key)

          loader.validate_full_chain(@cert_bundle, loader.crls)
          @errors += loader.errors
        end

        @crl_chain = loader.crls
        @crl = loader.crl
      end

      def errors
        @errors += @host.errors
      end

      def valid_until
        Time.now + @settings[:ca_ttl]
      end

      def extension_factory_for(ca, cert = nil)
        ef = OpenSSL::X509::ExtensionFactory.new
        ef.issuer_certificate  = ca
        ef.subject_certificate = cert if cert

        ef
      end

      def inventory_entry(cert)
        "0x%04x %s %s %s" % [cert.serial, format_time(cert.not_before),
                             format_time(cert.not_after), cert.subject]
      end

      def next_serial(serial_file)
        if File.exist?(serial_file)
          File.read(serial_file).to_i(16)
        else
          1
        end
      end

      def format_time(time)
        time.strftime('%Y-%m-%dT%H:%M:%S%Z')
      end

      def create_server_cert
        server_cert = nil
        server_key = @host.create_private_key(@settings[:keylength],
                                              @settings[:hostprivkey],
                                              @settings[:hostpubkey])
        if server_key
          server_csr = @host.create_csr(name: @settings[:certname], key: server_key)
          if @settings[:subject_alt_names].empty?
            alt_names = "DNS:puppet, DNS:#{@settings[:certname]}"
          else
            alt_names = @settings[:subject_alt_names]
          end

          server_cert = sign_authorized_cert(server_csr, alt_names)
        end

        return server_key, server_cert
      end

      def sign_authorized_cert(csr, alt_names = '')
        cert = OpenSSL::X509::Certificate.new
        cert.public_key = csr.public_key
        cert.subject = csr.subject
        cert.issuer = @cert.subject
        cert.version = 2
        cert.serial = next_serial(@settings[:serial])
        cert.not_before = CERT_VALID_FROM
        cert.not_after = valid_until

        return unless add_custom_extensions(cert)

        ef = extension_factory_for(@cert, cert)
        add_authorized_extensions(cert, ef)

        if !alt_names.empty?
          add_subject_alt_names_extension(alt_names, cert, ef)
        end

        cert.sign(@key, @digest)

        cert
      end

      def add_authorized_extensions(cert, ef)
        SERVER_EXTENSIONS.each do |ext|
          extension = ef.create_extension(*ext)
          cert.add_extension(extension)
        end

        # Status API access for the CA CLI
        cli_auth_ext = OpenSSL::X509::Extension.new(CLI_AUTH_EXT_OID, OpenSSL::ASN1::UTF8String.new("true").to_der, false)
        cert.add_extension(cli_auth_ext)
      end

      def add_subject_alt_names_extension(alt_names, cert, ef)
        alt_names_ext = ef.create_extension("subjectAltName", alt_names, false)
        cert.add_extension(alt_names_ext)
      end

      # This takes all the extension requests from csr_attributes.yaml and
      # adds those to the cert
      def add_custom_extensions(cert)
        extension_requests = @host.get_extension_requests(@settings[:csr_attributes])

        if extension_requests
          extensions = @host.validated_extensions(extension_requests)
          extensions.each do |ext|
            cert.add_extension(ext)
          end
        end

        @host.errors.empty?
      end

      def create_root_cert
        root_key = @host.create_private_key(@settings[:keylength])
        root_cert = self_signed_ca(root_key)
        root_crl = create_crl_for(root_cert, root_key)

        return root_key, root_cert, root_crl
      end

      def self_signed_ca(key)
        cert = OpenSSL::X509::Certificate.new

        cert.public_key = key.public_key
        cert.subject = OpenSSL::X509::Name.new([["CN", @settings[:root_ca_name]]])
        cert.issuer = cert.subject
        cert.version = 2
        cert.serial = 1

        cert.not_before = CERT_VALID_FROM
        cert.not_after  = valid_until

        ef = extension_factory_for(cert, cert)
        CA_EXTENSIONS.each do |ext|
          extension = ef.create_extension(*ext)
          cert.add_extension(extension)
        end

        cert.sign(key, @digest)

        cert
      end

      def create_crl_for(cert, key)
        crl = OpenSSL::X509::CRL.new
        crl.version = 1
        crl.issuer = cert.subject

        ef = extension_factory_for(cert)
        crl.add_extension(
          ef.create_extension(["authorityKeyIdentifier", "keyid:always", false]))
        crl.add_extension(
          OpenSSL::X509::Extension.new("crlNumber", OpenSSL::ASN1::Integer(0)))

        crl.last_update = CERT_VALID_FROM
        crl.next_update = valid_until
        crl.sign(key, @digest)

        # FIXME: Workaround a bug in jruby-openssl. Without this, #to_pem return an invalid CRL:
        # ----BEGIN X509 CRL-----
        # MAA=
        # -----END X509 CRL-----
        # See:
        # https://github.com/jruby/jruby-openssl/issues/163
        # https://github.com/jruby/jruby-openssl/pull/333
        crl = OpenSSL::X509::CRL.new(crl.to_der)

        crl
      end

      def create_intermediate_cert(root_key, root_cert)
        @key = @host.create_private_key(@settings[:keylength])
        int_csr = @host.create_csr(name: @settings[:ca_name], key: @key)
        @cert = sign_intermediate(root_key, root_cert, int_csr)
        @crl = create_crl_for(@cert, @key)

        return nil
      end

      def sign_intermediate(ca_key, ca_cert, csr)
        cert = OpenSSL::X509::Certificate.new

        cert.public_key = csr.public_key
        cert.subject = csr.subject
        cert.issuer = ca_cert.subject
        cert.version = 2
        cert.serial = 2

        cert.not_before = CERT_VALID_FROM
        cert.not_after = valid_until

        ef = extension_factory_for(ca_cert, cert)
        CA_EXTENSIONS.each do |ext|
          extension = ef.create_extension(*ext)
          cert.add_extension(extension)
        end

        cert.sign(ca_key, @digest)

        cert
      end

      def update_serial_file(serial)
        Puppetserver::Ca::Utils::FileSystem.write_file(@settings[:serial], serial.to_s(16), 0644)
      end
    end
  end
end

require "openssl"

module Sensu
  class Helpers
    extend ChefVaultCookbook if Kernel.const_defined?("ChefVaultCookbook")
    class << self
      def select_attributes(attributes, keys)
        attributes.to_hash.reject do |key, value|
          !Array(keys).include?(key.to_s) || value.nil?
        end
      end

      def sanitize(raw_hash)
        sanitized = Hash.new
        raw_hash.each do |key, value|
          # Expand Chef::DelayedEvaluator (lazy)
          value = value.call if value.respond_to?(:call)

          case value
          when Hash
            sanitized[key] = sanitize(value) unless value.empty?
          when nil
            # noop
          else
            sanitized[key] = value
          end
        end
        sanitized
      end

      def gem_binary
        if File.exists?("/opt/sensu/embedded/bin/gem")
          "/opt/sensu/embedded/bin/gem"
        elsif File.exists?('c:\opt\sensu\embedded\bin\gem.bat')
          'c:\opt\sensu\embedded\bin\gem.bat'
        else
          "gem"
        end
      end

      def data_bag_item(item, missing_ok=false, data_bag_name="sensu")
        raw_hash = Chef::DataBagItem.load(data_bag_name, item).delete_if { |k,v| k == "id" }
        encrypted = raw_hash.detect do |key, value|
          if value.is_a?(Hash)
            value.has_key?("encrypted_data")
          end
        end
        if encrypted
          if Chef::DataBag.load(data_bag_name).key? "#{item}_keys"
            chef_vault_item(data_bag_name, item)
          else
            secret = Chef::EncryptedDataBagItem.load_secret
            Chef::EncryptedDataBagItem.new(raw_hash, secret)
          end
        else
          raw_hash
        end
      rescue Chef::Exceptions::ValidationFailed,
        Chef::Exceptions::InvalidDataBagPath,
        Net::HTTPServerException => error
        missing_ok ? nil : raise(error)
      end

      def random_password(length=20, number=false, upper=false, lower=false, special=false)
        password = ""
        requiredOffset = 0
        requiredOffset += 1 if number
        requiredOffset += 1 if upper
        requiredOffset += 1 if lower
        requiredOffset += 1 if special
        length = requiredOffset if length < requiredOffset
        limit = password.length < (length - requiredOffset)

        while limit || requiredOffset > 0
          push = false
          c = ::OpenSSL::Random.random_bytes(1).gsub(/\W/, '')
          if c != ""
            if c =~ /[[:digit:]]/
              requiredOffset -= 1 if number
              number = false
            elsif c >= 'a' && c <= 'z'
              requiredOffset -= 1 if lower
              lower = false
            elsif c >= 'A' && c <= 'Z'
              requiredOffset -= 1 if upper
              upper = false
            else
              requiredOffset -= 1 if special
              special = false
            end
          end
          limit = password.length < (length - requiredOffset)
          if limit
            password << c
          end
        end
        password
      end

      # Wraps the Chef::Util::Windows::NetUser, returning false if the Win32 constant
      # is undefined, or returning false if the user does not exist. This indirection
      # seems like the most expedient way to make the sensu::_windows recipe testable
      # via chefspec on non-windows platforms.
      #
      # @param [String] the name of the user to test for
      # @return [TrueClass, FalseClass]
      def windows_user_exists?(user)
        if defined?(Win32)
          net_user = Chef::Util::Windows::NetUser.new(user)
          !!net_user.get_info rescue false
        else
          false
        end
      end

      # Wraps Win32::Service, returning false if the Win32 constant
      # is undefined, or returning false if the user does not exist. This indirection
      # seems like the most expedient way to make the sensu::_windows recipe testable
      # via chefspec on non-windows platforms.
      #
      # @param [String] the name of the service to test for
      # @return [TrueClass, FalseClass]
      def windows_service_exists?(service)
        if defined?(Win32)
          ::Win32::Service.exists?(service)
        else
          false
        end
      end

      # Derives Sensu package version strings for Redhat platforms.
      # When the desired Sensu version is '0.27.0' or later, the package
      # requires a '.elX' suffix.
      #
      # @param [String] Sensu version string
      # @param [String] Platform version
      # @param [String,NilClass] Suffix to override default '.elX'
      def redhat_version_string(sensu_version, platform_version, suffix_override = nil)
        bare_version = sensu_version.split('-').first
        if Gem::Version.new(bare_version) < Gem::Version.new('0.27.0')
          sensu_version
        else
          platform_major = Gem::Version.new(platform_version).segments.first
          suffix = suffix_override || ".el#{platform_major}"
          [sensu_version, suffix].join
        end
      end

      # We need a helper to determine whether to use rhel 6 or 7
      # Due to the change in amazon linux 2 versioning
      #
      # @param platform_version [String] The platform version, as reported by ohai
      def amazon_linux_2_rhel_version(platform_version)
        return "6" if /201\d/.match?(platform_version)
        # TODO: once we no longer support chef versions < 14.3.0 we should remove the check for amzon2 and remove this comment
        return "7" if platform_version == "2" || platform_version.include?("amzn2")
        raise "Unsupported Linux platform version #{platform_version} - rhel version unknown"
      end

      # Derives Sensu package version strings for Amazon Linux 2 platforms.
      # When the desired Sensu version is '0.27.0' or later, the package
      # requires a '.elX' suffix.
      #
      # @param sensu_version [String] Sensu version string
      # @param platform_version [String] Platform version
      # @param suffix_override [String,NilClass] Suffix to override default '.elX'
      def amazon_linux_2_version_string(sensu_version, platform_version, suffix_override = nil)
        bare_version = sensu_version.split('-').first
        if Gem::Version.new(bare_version) < Gem::Version.new('0.27.0')
          sensu_version
        else
          platform_major = Gem::Version.new(platform_version).segments.first
          suffix = suffix_override || ".el#{platform_major}"
          [sensu_version, suffix].join
        end
      end
      require 'mixlib/shellout'
      require 'chef/provider/ruby_block'
      # This function supports both files/dirs (at least on *nix),
      # assumes recursive changes, and does account for globbing
      # such as './**/*.rb'. I am not sure the feasibility of
      # doing non recursive changes and still supporting globbing
      # as the number of edgecases increase drastically.
      #
      # @param [String] A file path which supports globbing
      # @param [Integer] The file permissions you want to set
      def chmod_files(files, permissions = 644)
        ruby_block "chmod files: #{files} with permissions: #{permissions}" do
          block do
            Chef::Log.info "context: #{files}, permissions: #{permissions}, exist: #{!::Dir.glob(files).empty?}"
            chmod = Mixlib::ShellOut.new("chmod -R #{permissions} #{files}")
            chmod.run_command
            chmod.error!
          end
          action :run
          # we expand the list of files that might be used for globbing
          # purposes and test if the array is not empty.
          only_if { !::Dir.glob(files).empty? }
          # make me idempotent damn it!
          only_if do
            needs_change = []
            ::Dir.glob(files).each do |f|
              # we take the file stats and ask for the mode,
              # convert it to octal, and then take the last 4 chars.
              perm = ::File.stat(f).mode.to_s(8)[-4..-1]
              # rather than a normal string comparison we check
              # the substring to ensure that account for lack of
              # prepended 0 for permissions.
              unless perm.include?(permissions.to_s)
                needs_change << "file: #{f}, current_perm: #{perm}, target_perm: #{permissions}"
              end
            end
            if needs_change.any?
              Chef::Log.info "We needed to change the following files: #{needs_change}"
              true
            else
              false
            end
          end
        end
      end

      def sensu_ruby_version(path = '/opt/sensu/embedded/bin/ruby')
        if ::File.exist?(path)
          ruby_version = Mixlib::ShellOut.new("#{path} --version")
          ruby_version.run_command
          ruby_version.error!
          # extract major.minor.patch from full text version
          version = ruby_version.stdout.split(' ')[1].split('p')[0]
          # set patch to 0 as we only care about major & minor
          version.gsub(/\.\d{1,}$/, '.0')
        end
      end

      # end of functions
    end
  end
end

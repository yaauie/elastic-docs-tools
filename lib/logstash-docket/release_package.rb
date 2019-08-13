# encoding: utf-8

require_relative 'versioned_plugin'
require_relative 'util/threadsafe_deferral'

module LogstashDocket
  ##
  # A {@link ReleasePackage} represents a versioned artefact from a {@link Repository}
  #
  # It provides methods for interacting with the {@link VersionedPlugin}s that it provides.
  class ReleasePackage

    ##
    # Fetch a specific released package from rubygems.
    #
    # @param gem_name [String]: the gem name as published to rubygems
    # @param version [String]: the release version to fetch (optional:
    #                          if omitted, the resulting {@link ReleasePackage} will use the latest
    #                          published release's metadata and source from "master")`)
    #
    # @yieldparam gem_data [Hash{String=>Object}]: the gem data from rubygems.org
    # @yieldreturn [Source]: a {@link Source}, which will be used to get artifact contents etc.
    #
    # @return [ReleasePackage,nil]: returns a release package IFF relevant metadata could be fetched from rubygems.org
    def self.from_rubygems(gem_name, version=nil, &source_generator)
      repository = Repository.from_rubygems(gem_name, version, &source_generator)
      repository && repository.released_package(version)
    end

    attr_reader :version
    attr_reader :repository

    ##
    # @api private use {@link Repository#released_package} etc.
    #
    # @param repository [Repository]
    # @param version [String, nil]
    def initialize(repository, version, gem_data=nil)
      @repository = repository
      @version = version && Gem::Version.new(version)
      @rubygem_info = Util::ThreadsafeDeferral.for { gem_data || fetch_gem_data }

      @plugin_versions = Util::ThreadsafeDeferral.for { generate_plugin_versions }
    end

    ##
    # @return [Name]
    def name
      repository.name
    end

    ##
    # @return [String]: a short description suitable for logging
    def desc
      @desc ||= "#{name}@#{tag}"
    end

    ##
    # @return [String]: a git reference
    def tag
      @version ? "v#{@version}" : "master"
    end

    ##
    # @return [Enumerable[VersionedPlugin]]
    def plugins
      @plugin_versions.value
    end

    ##
    # @return [Time,nil]
    def release_date
      return nil unless version

      @release_date ||= repository.release_date(version)
    end

    ##
    # @return [String]
    def changelog_url
      repository.web_url("CHANGELOG.md", version)
    end

    ##
    # @return [String]
    def read_file_from_source(path)
      repository.read_file(path, version)
    end

    ##
    # @return [Boolean]
    def integration?
      plugins.any? { |plugin| plugin.kind_of?(VersionedPlugin::Packaged) }
    end

    ##
    # @return [Boolean]
    def ==(other)
      return false unless other.instance_of?(ReleasePackage)

      return false unless repository == other.repository
      return false unless version == other.version

      true
    end

    private

    ##
    # @api private
    # @return [Hash{String=>Object}]
    def rubygem_info
      @rubygem_info.value
    end

    ##
    # @api private
    # @return [Array[VersionedPlugin]]
    def generate_plugin_versions
      gem_metadata = rubygem_info.dig('metadata')

      return [VersionedPlugin::Standalone.new(name, self)] unless gem_metadata.include?('integration_plugins')

      packaged_plugins = rubygem_info.dig('metadata', 'integration_plugins').split(',').map(&:strip)

      packaged_plugins.map do |plugin_name|
        VersionedPlugin::Packaged.new(plugin_name, self) rescue $stderr.puts("#{desc}: skipping #{plugin_name}: #{$!}")
      end.compact
    end

    def fetch_gem_data
      gem_data_version = version || repository.rubygem_info.latest
      gem_data_version || fail("No releases on rubygems")

      repository.rubygem_info.for_version(gem_data_version) || fail("[#{desc}]: no gem data available")
    end
  end
end
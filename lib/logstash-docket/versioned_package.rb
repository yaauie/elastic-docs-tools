# encoding: utf-8

require_relative 'versioned_plugin'

module LogstashDocket
  class VersionedPackage

    def self.from_rubygems(gem_name, version, &source_generator)
      Repository.from_rubygems(gem_name, version, &source_generator).versioned_package(version)
    end

    attr_reader :version
    attr_reader :repository

    def initialize(repository, version)
      @repository = repository
      @version = version && Gem::Version.new(version)

      # TODO: make this lazy, which requires threadsafety
      @plugin_versions = generate_plugin_versions
    end

    def name
      repository.name
    end

    def desc
      @desc ||= "#{name}@#{tag}"
    end

    def tag
      @version ? "v#{@version}" : "master"
    end

    def plugins
      @plugin_versions
    end

    def release_date
      return nil unless version

      @release_date ||= repository.release_date(version)
    end

    def changelog_url
      repository.web_url("CHANGELOG.md", version)
    end

    def read_file_from_source(path)
      repository.read_file(path, version)
    end

    def integration?
      !!rubygem_info.dig('metadata', 'integration_plugins')
    end

    def ==(other)
      return false unless other.instance_of?(VersionedPackage)

      return false unless repository == other.repository
      return false unless version == other.version

      true
    end

    private

    def rubygem_info
      map = version ? @repository.rubygem_info.for_version(version.to_s) : @repository.rubygem_info.latest
      map || fail("NO GEM DATA: #{desc}")
    end

    def generate_plugin_versions
      gem_metadata = rubygem_info.dig('metadata')

      return [VersionedPlugin::Standalone.new(name, self)] unless gem_metadata.include?('integration_plugins')

      packaged_plugins = rubygem_info.dig('metadata', 'integration_plugins').split(',').map(&:strip)

      packaged_plugins.map do |plugin_name|
        VersionedPlugin::Packaged.new(plugin_name, self) rescue $stderr.puts("#{desc}: skipping #{plugin_name}: #{$!}")
      end.compact
    end
  end
end
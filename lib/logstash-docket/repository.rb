# encoding: utf-8

require_relative 'util/threadsafe_index'

require_relative 'versioned_package'
require_relative 'source'
require_relative 'rubygem_info'

module LogstashDocket
  ##
  # A `Repository` is a named plugin matching a gem on rubygems.
  # it has one or more versions,
  class Repository
    def self.from_rubygems(gem_name, gem_version=nil, &source_generator)
      rubygem_info = RubygemInfo.new(gem_name)
      gemdata = gem_version ? rubygem_info.for_version(gem_version) : rubygem_info.latest

      source = source_generator.call(gemdata)

      new(nil, gem_name, source, rubygem_info)
    end

    def self.from_github(org, repo)
      source = Source::Github.new(org, repo)

      new(nil, repo, source, RubygemInfo.new(repo))
    end

    private_class_method(:new)

    attr_reader :name
    attr_reader :rubygem_info # @api private

    def initialize(context, name, source, rubygem_info)
      @context = context
      @name = name
      @source = source || Source.from_rubygems(context, name)

      @package_versions = Util::ThreadsafeIndex.new { |version| VersionedPackage.new(self, version) }

      @rubygem_info = rubygem_info
    end

    def versioned_packages(include_prerelease=false)
      return enum_for(:versioned_packages) unless block_given?

      @rubygem_info.versions.each do |version|
        next unless include_prerelease || !Gem::Version.new(version).prerelease?

        yield versioned_package(version)
      end
    end

    def versioned_package(version)
      @package_versions.for(version)
    end

    def last_release_date
      latest_version = @rubygem_info.latest

      latest_version && @package_versions.for(latest_version).release_date
    end

    def read_file(filename, version=nil)
      @source.read_file(filename, version)
    end

    def web_url(filename, version)
      @source.web_url(filename, version)
    end

    ##
    # @return [Time]
    def release_date(version)
      return nil if version.nil?

      gem_info = @rubygem_info.for_version(version)
      created_at = gem_info && gem_info.dig('created_at')

      created_at && Time.parse(created_at)
    end
  end
end
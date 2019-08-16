# encoding: utf-8

require_relative 'util/threadsafe_index'
require_relative 'util/threadsafe_deferral'

require_relative 'release_package'
require_relative 'plugin'
require_relative 'source'
require_relative 'rubygem_info'

module LogstashDocket
  ##
  # A `Repository` contains the complete source and release history of a named artefact
  # that is pushed to rubygems. It has a {@link Source}, which allows us to extract contents
  # of the versioned artefacts, and provides methods for listing releases.
  #
  class Repository
    ##
    # Construct a new {@link Repository} from a gem name and optional version, using metatata
    # from the latest release on rubygems.
    #
    # @param gem_name [String]: the name of the gem on rubygems.org
    # @param version [String]: an X.Y.Z version specifier (default: latest)
    #
    # @yieldparam gem_data [Hash{String=>Object}]: the gem data from rubygems.org
    # @yieldreturn [Source]: a {@link Source}, which will be used to get artifact contents etc.
    #
    # @return [Repository,nil]: returns a {@link Repository} IFF one could be deduced from gem metadata
    def self.from_rubygems(gem_name, gem_version=nil, &source_generator)
      rubygem_info = RubygemInfo.new(gem_name)
      if rubygem_info.nil?
        $stderr.puts("[gem:#{gem_name}]: release metadata unavailable from rubygems.org")
        return nil
      end

      gem_version ||= rubygem_info.latest

      gemdata = rubygem_info.for_version(gem_version)
      if gemdata.nil?
        $stderr.puts("[gem:#{gem_name}]: release `#{gem_version}` not published to rubygems.org")
        return nil
      end

      source = source_generator.call(gemdata)

      new(gem_name, source, rubygem_info)
    end

    ##
    # Construct a new {@link Repository} from a known {@link Source}
    #
    # @param name [String]: the name of the artefact as registered on rubygems.org
    # @param source [Source]: a {@link Source}, which will be used to get artifact contents etc.
    def self.from_source(name, source)
      new(name, source)
    end

    private_class_method(:new)

    attr_reader :name
    attr_reader :source

    ##
    # @api private
    def initialize(name, source, rubygem_info = nil)
      @name = name
      @source = source

      @package_versions = Util::ThreadsafeIndex.new { |version| ReleasePackage.new(self, version) }
      @plugin_versions = Util::ThreadsafeIndex.new { |version| Plugin::TopLevel.new(repository: self, version: version) }

      @rubygem_info = Util::ThreadsafeDeferral.for { rubygem_info || RubygemInfo.new(name) }
    end

    ##
    # @return [String]: a short description suitable for logging
    def desc
      @desc ||= "[repository:#{name}]"
    end

    ##
    # Returns an {@link Enumerable} containing all {@link ReleasePackage}s from
    # rubygems.org that have a corresponding release tag in our `source`.
    #
    # @return Enumerable[ReleasePackage]
    def source_tagged_releases(include_prerelease=false)
      return enum_for(:source_tagged_releases, include_prerelease) unless block_given?

      released_plugins(include_prerelease).each do |released_plugin|
        next unless source.release_tags.include?(released_plugin.tag)

        yield released_plugin
      end
    end

    def released_plugins(include_prerelease=false)
      return enum_for(:released_plugins, include_prerelease) unless block_given?

      rubygem_info.versions.each do |version|
        next unless include_prerelease || !Gem::Version.new(version).prerelease?

        yield released_plugin(version)
      end
    end

    def released_plugin(version)
      @plugin_versions.fetch(version)
    end

    ##
    # Returns an {@link Enumerable} containing all {@link ReleasePackage}s from
    # rubygems.org.
    #
    # @return Enumerable[ReleasePackage]
    def released_packages(include_prerelease=false)
      return enum_for(:released_packages, include_prerelease) unless block_given?

      rubygem_info.versions.each do |version|
        next unless include_prerelease || !Gem::Version.new(version).prerelease?

        yield released_package(version)
      end
    end

    ##
    # Fetch a {@link ReleasePackage} for the provided version
    #
    # @param version [#to_s, nil]: the version of release we want (optional: unreleased master, using latest release's gem metadata)
    # @return [ReleasePackage]
    def released_package(version)
      @package_versions.fetch(version)
    end

    ##
    # @return [Time]
    def last_release_date
      latest_version = rubygem_info.latest

      latest_version && released_package(latest_version).release_date
    end

    ##
    # @return [ReleasePackage]: the last available release, or nil if there are no releases
    def last_release
      latest_version = rubygem_info.latest

      latest_version && released_plugin(latest_version)
    end

    ##
    # @api private
    # @return [String]
    def read_file(filename, version=nil)
      @source.read_file(filename, version)
    end

    ##
    # @api private
    # @return [String]
    def web_url(filename, version)
      @source.web_url(filename, version)
    end

    ##
    # Fetch the release date of a version, without instantiating a {@link ReleasePackage}
    #
    # @return [Time]
    def release_date(version)
      return nil if version.nil?

      gem_info = rubygem_info.for_version(version)
      created_at = gem_info && gem_info.dig('created_at')

      created_at && Time.parse(created_at)
    end

    ##
    # @api private
    # @return [RubygemInfo]
    def rubygem_info
      @rubygem_info.value
    end
  end
end
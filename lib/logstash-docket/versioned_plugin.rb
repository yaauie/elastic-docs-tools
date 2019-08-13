# encoding: utf-8

module LogstashDocket
  ##
  # Implementations of {@link PluginVersion} are named plugins
  # at a specified version, that are a part of a single source
  # package.
  #
  # There may be one or more versions of plugins that share a
  # canonical name, but they are not guaranteed to come from the
  # same repository.s
  #
  # @see VersionedPlugin::Standalone
  # @see VersionedPlugin::Packaged
  module VersionedPlugin
    attr_reader :canonical_name
    attr_reader :name
    attr_reader :type
    attr_reader :package

    ##
    # @api private use {@link ReleasePackage#plugins}
    # @param name [String]
    # @param package_source [DocGen::ReleasePackage]
    def initialize(canonical_name, release_package)
      @canonical_name = canonical_name.dup.freeze
      if canonical_name !~ %r{\Alogstash-(?<type>input|filter|codec|output)-(?<name>.*)}
        fail(ArgumentError "unsupported plugin name `#{canonical_name}`")
      end
      @type = Regexp.last_match(:type).freeze
      @name = Regexp.last_match(:name).freeze

      @package = release_package
    end

    ##
    # @see ReleasePackage#version
    def version
      package.version
    end

    ##
    # @see ReleasePackage#release_date
    def release_date
      package.release_date
    end

    ##
    # @see ReleasePackage#changelog_url
    def changelog_url
      package.changelog_url
    end

    ##
    # @see ReleasePackage#tag
    def tag
      package.tag
    end

    ##
    # @return [String]
    def documentation
      package.read_file_from_source(documentation_path)
    end

    ##
    # @return [String]: a short description suitable for logging
    def desc
      fail NotImplementedError
    end

    ##
    # @return [Boolean]
    def ==(other)
      return false unless other.kind_of?(VersionedPlugin)

      return false unless package == other.package
      return false unless type == other.type
      return false unless name == other.name

      true
    end

    ##
    # A {@link PluginVersion::Standalone} is a plugin that is the _only_
    # plugin contained in its source at the specified version.
    class Standalone
      include VersionedPlugin

      def documentation
        package.read_file_from_source('docs/index.asciidoc')
      end

      def desc
        package.desc
      end
    end

    ##
    # A {@link PluginVersion::Packaged} is a {@link PluginVersion} that is
    # a part of a multi-packaging.
    class Packaged
      include VersionedPlugin

      def documentation
        # falls through to alternate path to support integration plugins
        # from before concept was fully fleshed-out.
        package.read_file_from_source("docs/#{type}-#{name}.asciidoc") ||
          package.read_file_from_source("docs/index-#{type}.asciidoc")
      end

      def desc
        @desc ||= "#{package.desc}/#{name}"
      end
    end
  end
end
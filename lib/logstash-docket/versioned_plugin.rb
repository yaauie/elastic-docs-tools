# encoding: utf-8

module LogstashDocket
  ##
  # Implementations of {@link PluginVersion} are named plugins
  # at a specified version, that are a part of a single source
  # package.
  #
  # @see VersionedPlugin::Standalone
  # @see VersionedPlugin::Packaged
  module VersionedPlugin
    attr_reader :canonical_name
    attr_reader :name
    attr_reader :type
    attr_reader :package

    ##
    # @param name [String]
    # @param package_source [DocGen::VersionedPackage]
    def initialize(canonical_name, versioned_package)
      @canonical_name = canonical_name.dup.freeze
      if canonical_name !~ %r{\Alogstash-(?<type>input|filter|codec|output)-(?<name>.*)}
        fail(ArgumentError "unsupported plugin name `#{canonical_name}`")
      end
      @type = Regexp.last_match(:type).freeze
      @name = Regexp.last_match(:name).freeze

      @package = versioned_package
    end

    def version
      package.version
    end

    def release_date
      package.release_date
    end

    def changelog_url
      package.changelog_url
    end

    def tag
      package.tag
    end

    ##
    # @return [String]
    def documentation
      package.read_file_from_source(documentation_path)
    end

    def desc
      fail NotImplementedError
    end

    def ==(other)
      return false unless other.kind_of?(VersionedPlugin)

      return false unless package == other.package
      return false unless name == other.name

      true
    end

    protected

    ##
    # @return [String]
    def documentation_path
      fail NotImplementedError
    end

    ##
    # A {@link PluginVersion::Standalone} is a plugin that is the _only_
    # plugin contained in its source at the specified version.
    class Standalone
      include VersionedPlugin

      def documentation_path
        'docs/index.asciidoc'
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

      def documentation_path
        "docs/#{plugin_name}.asciidoc"
      end

      def desc
        @desc ||= "#{package.desc}/#{name}"
      end
    end
  end
end
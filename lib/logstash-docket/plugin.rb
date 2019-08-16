# encoding: utf-8

module LogstashDocket
  ##
  # A {@link Plugin} represents a versioned release of a Logstash Plugin.
  #
  # It provides metadata about the plugin version and methods for retrieving
  # plugin documentation from its {@link Repository}.
  #
  # There are two implementations of this interface module:
  #
  #  - {@link Plugin::TopLevel}, representing traditional plugins backed directly
  #    by a named and versioned artifact on rubygems.org, AND
  #  - {@link Plugin::Wrapped}, representing plugins that are packaged _inside_
  #    an "integration" {@link Plugin::TopLevel}.
  #
  module Plugin

    ##
    # @return [String]
    attr_reader :name

    ##
    # @return [String]
    attr_reader :type

    ##
    # @return [String]
    attr_reader :canonical_name

    ##
    # @api private
    #
    # @param type [String]
    # @param name [String]
    def initialize(type:, name:)
      @type = type
      @name = name

      @canonical_name = "logstash-#{type}-#{name}"
    end

    ##
    # @return [Gem::Version]
    def version
      fail NotImplementedError
    end

    ##
    # @return [Time,nil]
    def release_date
      fail NotImplementedError
    end

    ##
    # @return [String]
    def changelog_url
      fail NotImplementedError
    end

    ##
    # @return [String]
    def tag
      fail NotImplementedError
    end

    ##
    # @return [String]
    def documentation
      fail NotImplementedError
    end

    ##
    # @override each
    #   Returns an {@link Enumerable} containing each {@link Plugin} that
    #   is provided by this {@link Plugin}, including itself and any embedded
    #   plugins (e.g., an integration plugin contains multiple plugins).
    #   @return [Enumerable[Plugin]]
    #
    # @override each(&block)
    #   Yields each {@link Plugin} that is provided by this {@link Plugin},
    #   including itself and any embedded plugins (e.g., an integration plugin
    #   provides multiple plugins).
    #   @yieldparam [Plugin]
    #   @yieldreturn [void]
    #   @return [void]
    def each
      fail NotImplementedError
    end

    ##
    # @return [Hash{String=>Object}]
    def rubygem_info
      fail NotImplementedError
    end

    ##
    # A string suitable for describing this {@link Plugin} in log messages
    #
    # @return [String]
    def desc
      fail NotImplementedError
    end

    ##
    # @return [Repository]
    def repository
      fail NotImplementedError
    end

    ##
    # @return [Boolean]
    def ==(other)
      return false unless other.kind_of?(Plugin)

      return false unless self.type == other.type
      return false unless self.name == other.name
      return false unless self.version == other.version

      true
    end

    ##
    # Attempts to instantiate a {@link Plugin::TopLevel} from the named gem, using
    # the optionally-provided version as a hint.
    #
    # @param gem_name [String]
    # @param version [String, nil]: (optional: when omitted, source's master will
    #                               be used with the latest-available published gem metadata)
    #
    # @yieldparam [Hash{String=>Object}]: gem metadata
    # @yieldreturn [Source]
    #
    # @return [Plugin::TopLevel,nil]
    def self.from_rubygems(gem_name, version=nil, &source_generator)
      repository = Repository.from_rubygems(gem_name, version, &source_generator)
      repository && repository.released_plugin(version)
    end

    ##
    # A {@link Plugin::TopLevel} is an implementation of {@link Plugin} that
    # is used to represent plugins that are directly available by name on
    # rubygems.org.
    #
    # It can be used to represent self-contained plugins:
    #  - filter,
    #  - input,
    #  - output, OR
    #  - codec.
    #
    # It can also be used to represent top-level "integration" plugins that
    # themselves contain multiple "wrapped" plugins (e.g., {@link Plugin::Wrapped}).
    #
    # @api public
    class TopLevel

      SUPPORTED_TYPES = Set.new(%w(input output filter codec integration).map(&:freeze)).freeze
      EMPTY = Array.new.freeze

      include Plugin

      ##
      # @see Plugin#repository
      attr_reader :repository

      ##
      # @see Plugin#version
      attr_reader :version

      ##
      # @see Plugin#initialize
      #
      # @param repository [Repository]
      # @param version [String]
      def initialize(repository:,version:)
        if repository.name !~ %r{\Alogstash-(?<type>[a-z]+)-(?<name>.*)}
          fail(ArgumentError, "invalid plugin name `#{repository.name}`")
        end
        super(type: Regexp.last_match(:type), name: Regexp.last_match(:name))

        fail("#{desc} plugin type #{type} not supported as a top-level plugin") unless SUPPORTED_TYPES.include?(type)

        @repository = repository
        @version = version && Gem::Version.new(version)

        @rubygem_info = Util::ThreadsafeDeferral.for(&method(:fetch_rubygem_info))
        @wrapped_plugins = Util::ThreadsafeDeferral.for(&method(:generate_wrapped_plugins))
      end

      ##
      # @see Plugin#release_date
      def release_date
        version && repository.release_date(version)
      end

      ##
      # @see Plugin#documentation
      def documentation
        repository.read_file("docs/index.asciidoc", version)
      end

      ##
      # @see Plugin#changelog_url
      def changelog_url
        repository.web_url("CHANGELOG.md", version)
      end

      ##
      # @see Plugin#tag
      def tag
        version ? "v#{version}" : "master"
      end

      ##
      # @see Plugin#rubygem_info
      def rubygem_info
        @rubygem_info.value
      end

      ##
      # @see Plugin#desc
      def desc
        @desc ||= "[plugin:#{canonical_name}@#{tag}]"
      end

      ##
      # @see Plugin#each
      def each
        return enum_for(:each) unless block_given?

        yield self

        wrapped_plugins.each do |wrapped_plugin|
          yield wrapped_plugin
        end
      end

      ##
      # Returns zero or more {@link Plugin::Wrapped} provided by
      # an "integration" plugin.
      #
      def wrapped_plugins
        @wrapped_plugins.value
      end

      ##
      # @see Plugin#==
      def ==(other)
        return false unless super

        return false unless other.kind_of?(TopLevel)

        return false unless self.repository == other.repository
        return false unless self.version == other.version

        return true
      end

      private

      def fetch_rubygem_info
        gem_data_version = version || repository.rubygem_info.latest
        gem_data_version || fail("No releases on rubygems")

        repository.rubygem_info.for_version(gem_data_version) || fail("[#{desc}]: no gem data available")
      end

      def generate_wrapped_plugins
        rubygem_info || fail("Gem info not available on rubygems")

        wrapped_plugin_canonical_names_csv = rubygem_info.dig('metadata','integration_plugins')
        return EMPTY if wrapped_plugin_canonical_names_csv.nil?

        wrapped_plugin_canonical_names_csv.split(',').map(&:strip).map do |wrapped_canonical_name|
          if wrapped_canonical_name !~ %r{\Alogstash-(?<type>[a-z]+)-(?<name>.*)}
            fail(ArgumentError "unsupported plugin name `#{canonical_name}`")
          end
          Wrapped.new(wrapper: self, type: Regexp.last_match(:type), name: Regexp.last_match(:name))
        end.freeze
      end
    end

    ##
    # A {@link Plugin::Wrapped} is a {@link Plugin} that is provided within
    # a {@link Plugin::TopLevel} "integration" plugin.
    #
    # @api semiprivate (@see Plugin::TopLevel#wrapped_plugins)
    class Wrapped
      SUPPORTED_TYPES = Set.new(%w(input output filter codec).map(&:freeze)).freeze

      include Plugin

      ##
      # @see Plugin#
      #
      # @param wrapper [Plugin::TopLevel]
      def initialize(wrapper:, **args)
        super(**args)

        @wrapper = wrapper

        fail("#{desc} plugin type #{type} not supported as a wrapped plugin") unless SUPPORTED_TYPES.include?(type)
        fail(ArgumentError) unless wrapper.kind_of?(TopLevel)
      end

      ##
      # @see Plugin#repository
      def repository
        @wrapper.repository
      end

      ##
      # @see Plugin#version
      def version
        @wrapper.version
      end

      ##
      # @see Plugin#documentation
      def documentation
        repository.read_file("docs/#{type}-#{name}.asciidoc", version)
      end

      ##
      # @see Plugin#rubygem_info
      def rubygem_info
        @wrapper.rubygem_info
      end

      ##
      # @see Plugin#release_date
      def release_date
        @wrapper.release_date
      end

      ##
      # @see Plugin#changelog_url
      def changelog_url
        @wrapper.changelog_url
      end

      ##
      # @see Plugin#tag
      def tag
        @wrapper.tag
      end

      ##
      # @see Plugin#
      def desc
        @desc ||= "[plugin:#{@wrapper.canonical_name}/#{canonical_name}@#{tag}]"
      end

      ##
      # @see Plugin#
      def ==(other)
        return false unless super

        return false unless other.kind_of?(Wrapped)

        return false unless self.wrapper == other.wrapper

        return true
      end

      protected

      attr_reader :wrapper
    end
  end
end
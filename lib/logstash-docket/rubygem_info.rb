# encoding: utf-8

module LogstashDocket
  ##
  # In order to avoid hitting rubygems.org too frequently, a `RubygemInfo` caches
  # metadata from the API about a specific gem.
  #
  # Use `Context::rubygem_info(gem_name)` to get context-cached instances.
  class RubygemInfo
    def initialize(gem_name)
      @gem_name = gem_name
      @mutex = Mutex.new
    end

    def versions
      gemdata_by_version.keys
    end

    def for_version(version)
      gemdata_by_version.fetch(version.to_s)
    end

    def latest
      versions.first
    end

    private

    def gemdata_by_version
      @gemdata_by_version || @mutex.synchronize do
        @gemdata_by_version ||= fetch_versions_from_rubygems
      end
    end

    def fetch_versions_from_rubygems
      $stderr.puts("[#{@gem_name}]: fetching versions from rubygems\n")
      uri = URI("https://rubygems.org/api/v1/versions/#{@gem_name}.json")
      response = Stud::try(5.times) do
        r = Net::HTTP.get_response(uri)
        if r.kind_of?(Net::HTTPSuccess)
          r
        elsif r.kind_of?(Net::HTTPNotFound)
          nil
        elsif r.kind_of?(Net::HTTPTooManyRequests)
          sleep 1
          raise "TOO MANY REQUESTS #{uri}"
        else
          raise "Fetch rubygems metadata #{uri} failed: #{r}"
        end
      end
      body = response && response.body

      if body.nil?
        $stderr.puts("[#{@gem_name}]: failed to fetch versions.")
        return {}
      end

      # HACK: One of our default plugins, the webhdfs, has a bad encoding in the
      # gemspec which make our parser trip with this error:
      #
      # Encoding::UndefinedConversionError message: ""\xC3"" from ASCII-8BIT to
      # UTF-8. We dont have much choice than to force utf-8.
      body.encode(Encoding::UTF_8, :invalid => :replace, :undef => :replace)

      JSON.parse(body)
          .sort_by { |gem_data| Gem::Version.new(gem_data['number']) }
          .reverse
          .each_with_object({}) do |gem_data, index|
            version = gem_data['number']
            index[version] = gem_data
          end
    end
  end
end
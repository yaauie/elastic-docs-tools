# encoding: utf-8

module LogstashDocket
  module Source
    def read_file(filename, version=nil)
      fail NotImplementedError
    end

    def web_url(filename, version=nil)
      fail NotImplementedError
    end

    class Github
      include Source

      attr_reader :org
      attr_reader :repo

      def initialize(org, repo)
        @org = org
        @repo = repo
      end

      def read_file(filename, version=nil)
        uri = URI.parse("https://raw.githubusercontent.com/#{org}/#{repo}/#{ref(version)}/#{filename}")
        $stderr.puts("  < `#{uri}`")
        response = Net::HTTP.get(uri)

        return nil if response.start_with?('404: Not Found')

        response
      end

      def web_url(filename, version=nil)
        "https://github.com/#{org}/#{repo}/blob/#{ref(version)}/#{filename}"
      end

      private

      def ref(version)
        version ? "v#{version}" : 'master'
      end
    end
  end
end
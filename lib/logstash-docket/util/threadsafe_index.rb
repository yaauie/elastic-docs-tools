# encoding: utf-8

require 'thread' # Mutex

module LogstashDocket
  module Util
    class ThreadsafeIndex
      def initialize(&generator)
        @index = Hash.new
        @mutex = Mutex.new
        @generator = generator
      end

      def for(key, create_missing=true)
        @index.fetch(key) do
          return nil unless create_missing

          @mutex.synchronize do
            return @index.fetch(key) if @index.include?(key)

            @index.store(key, @generator.call(key))
          end
        end
      end

      def each
        return enum_for(:each) unless block_given?

        @mutex.synchronize { @index.to_a }.each do |key, value|
          yield key, value
        end
      end

      def each_value
        each.map(&:last)
      end

      def clear
        @mutex.synchronize { @index.clear }
      end
    end
  end
end

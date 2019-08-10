# encoding: utf-8

require 'thread' # Mutex

module LogstashDocket
  module Util
    class ThreadsafeWrapper
      def self.for(object)
        new(object)
      end
      private_class_method :new

      def initialize(object)
        @object = object
        @mutex = Mutex.new
      end

      def method_missing(method, *args, &block)
        _with_reentrant_lock do
          @object.public_send(method, *args, &block)
        end
      end

      def respond_to_missing?(method, include_private = false)
        @object.respond_to?(method, include_private)
      end

      private

      def _with_reentrant_lock
        if @mutex.owned?
          yield
        else
          @mutex.synchronize { yield }
        end
      end
    end
  end
end
require 'pooled_redis/version'
require 'connection_pool'

# If someone added hiredis to Gemfile, I hope he want to use it.
# This makes all Redis.new use hiredis.
if defined?(Hiredis)
  begin
    require 'redis/connection/hiredis'
  rescue LoadError
  end
end

ConnectionPool.class_eval do
  # Wraps pool and proxies every method to checked out connection.
  # Similar to Wrapper, but works on existing pool.
  class SimpleConnection < BasicObject
    def initialize(pool)
      @pool = pool
    end

    private

    def method_missing(name, *args, &block)
      @pool.with { |x| x.send name, *args, &block }
    end

    def respond_to_missing?(name, include_all = false)
      @pool.with { |x| x.respond_to?(name, include_all) }
    end
  end

  def simple_connection
    SimpleConnection.new(self)
  end
end

module PooledRedis
  class << self
    def extend_rails
      Rails.class_eval { extend PooledRedis } if defined?(Rails)
    end

    def setup_rails_cache(app)
      # We need to use initializer to be able to access
      # Rails.configuration.database_configuration.
      app.initializer :configure_cache, before: :initialize_cache, group: :all do
        cache_config = Rails.configuration.
          database_configuration[Rails.env]['cache'].try!(:with_indifferent_access)
        adapter = cache_config.try!(:delete, :adapter).try!(:to_sym)
        next unless adapter
        if adapter == :redis_store
          # Workaround to support `:db` option:
          pool_config ||= {
            pool:     cache_config.delete(:pool)    || 5,
            timeout:  cache_config.delete(:timeout) || 5,
          }
          cache_config = {
            pool: ConnectionPool.new(pool_config) { Redis::Store.new(cache_config) }
          }
        end
        app.config.cache_store = adapter, cache_config
      end
    end
  end

  # Override this method unless using Rails.
  def redis_config
    @redis_config ||= begin
      config = ActiveRecord::Base.connection_config[:redis].with_indifferent_access
      config[:logger] = Rails.logger if config.delete(:debug)
      require 'redis/namespace' if config[:namespace]
      config
    end
  end

  def redis_pool_config
    @redis_pool_config ||= {
      pool:     redis_config.delete(:pool)    || 5,
      timeout:  redis_config.delete(:timeout) || 5,
    }
  end

  def redis_pool
    @redis_pool ||= begin
      block = if redis_config[:block]
        redis_config[:block]
      elsif redis_config[:namespace]
        -> { Redis::Namespace.new(redis_config[:namespace], redis_config) }
      else
        -> { Redis.new(redis_config) }
      end
      ConnectionPool.new(redis_pool_config, &block)
    end
  end

  def redis
    @redis ||= redis_pool.simple_connection
  end
end

PooledRedis.extend_rails

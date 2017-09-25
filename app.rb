require 'mongo'
require 'timeout'
require 'logger'
require 'redis'

NULL_LOGGER = Logger.new('/dev/null')

# healthcheck interface
module Healthcheckable
  def status
    raise NotImplemented
  end
end

# healthcheck abstraction
class Status
  HEALTH = 'health'.freeze
  UNHEALTH = 'unhealth'.freeze

  attr_accessor :status, :msg, :name

  def self.new_unhealth_status(attrs = {})
    new(status: UNHEALTH, **attrs)
  end

  def self.new_health_status(attrs = {})
    new(status: HEALTH, **attrs)
  end

  def initialize(attrs)
    @status = attrs[:status]
    @msg    = attrs[:msg]
    @name   = attrs[:name]
  end

  def health?
    status == HEALTH
  end

  def to_s
    "service: #{name} - msg: #{msg}"
  end
end

# base Healchecker
class Healchecker
  private

    def with_timeout(timeout)
      Timeout.timeout(timeout) { yield }
    end
end

# Mongo healthcheck implementation
class MongoHealchecker < Healchecker
  include Healthcheckable

  def perform
    with_timeout(ENV['MONGO_TIMEOUT'].to_i) { do_status_check }
  end

  def do_status_check
    client.list_databases
  end

  def status
    perform
    Status.new_health_status(name: :mongo)
  rescue Timeout::Error => e
    Status.new_unhealth_status(msg: "Mongo Timeout: #{e.message}", name: :mongo)
  rescue => e
    Status.new_unhealth_status(msg: e.message, name: :mongo)
  end

  def client
    @client ||= Mongo::Client.new([ENV['MONGO_HOST']], logger: NULL_LOGGER)
  end
end

# Redis healthcheck implementation
class RedisHealchecker < Healchecker
  include Healthcheckable

  def perform
    with_timeout(ENV['REDIS_TIMEOUT'].to_i) { do_status_check }
  end

  def do_status_check
    client.ping
  end

  def status
    perform
    Status.new_health_status(name: :redis)
  rescue Timeout::Error => e
    Status.new_unhealth_status(msg: "Redis Timeout: #{e.message}", name: :redis)
  rescue SocketError, Redis::CannotConnectError => e
    Status.new_unhealth_status(msg: e.message, name: :redis)
  end

  def client
    @client ||= Redis.new(url: ENV['REDIS_HOST'])
  end
end

SERVICES = [MongoHealchecker, RedisHealchecker].freeze

# check all services
unhealth_status = catch(Status::UNHEALTH) do
  SERVICES.each do |service|
    status = service.new.status
    throw(Status::UNHEALTH, status) unless status.health?
  end

  puts 'WORKING'
end

puts unhealth_status if unhealth_status

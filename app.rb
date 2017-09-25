require 'mongo'
require 'timeout'
require 'logger'
require 'redis'
require 'webrick'
require 'thread'

NULL_LOGGER = Logger.new('/dev/null')

# healthcheck interface
module Healthcheckable
  def status
    raise NotImplemented
  end
end

# healthcheck abstraction
class Status
  STATES = {
    health:   HEALTH = 'health'.freeze,
    unhealth: UNHEALTH = 'unhealth'.freeze
  }.freeze

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
  ensure
    client.close
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
  ensure
    client.quit
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

# Healchecker executable
module Run
  module_function

  def run_healthcheck(service)
    service.new.status
  end

  def run_healthcheck_for(services, wait=ENV["WAIT"].to_i)
    catch(Status::UNHEALTH) do
      services.each do |service|
        status = run_healthcheck(service)
        sleep(wait)
        throw(Status::UNHEALTH, status) unless status.health?
      end
      nil
    end
  end

  def run_healthcheck_in_parallel(services, wait=ENV["WAIT"].to_i)
    semaphore = Mutex.new
    catch(Status::UNHEALTH) do
      ts = services.map do |service|
        Thread.new do
          status = nil
          semaphore.synchronize do
            status = run_healthcheck(service)
          end
          sleep(wait)
          throw(Status::UNHEALTH, status) unless status.health?
        end
      end
      ts.map(&:join)
      nil
    end
  end
end

SERVICES = [MongoHealchecker, RedisHealchecker].freeze

# HealcheckRoute
class Routes < WEBrick::HTTPServlet::AbstractServlet
  def with_duration
    start_time = Time.now
    yield
    "%.3f" % (Time.now - start_time)
  end
end

class HealcheckRoute < Routes
  def do_GET(_, response)
    unhealth_status = nil
    duration = with_duration do
      unhealth_status = Run.run_healthcheck_for(SERVICES)
    end

    response.status = 200
    response['Content-Type'] = 'text/plain'
    response.body = unhealth_status&.to_s || "WORKING %s ms " % duration
  end
end

class ParallelHealcheckRoute < Routes
  def do_GET(_, response)
    unhealth_status = nil
    duration = with_duration do
      unhealth_status = Run.run_healthcheck_in_parallel(SERVICES)
    end

    response.status = 200
    response['Content-Type'] = 'text/plain'
    response.body = unhealth_status&.to_s || "WORKING %s ms" % duration
  end
end

server = WEBrick::HTTPServer.new(Port: ENV['WEB_SERVER_PORT'])
trap 'INT' do
  server.shutdown
end
server.mount '/healthcheck', HealcheckRoute
server.mount '/parallel-healthcheck', ParallelHealcheckRoute
server.start

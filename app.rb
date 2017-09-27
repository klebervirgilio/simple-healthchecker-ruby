# frozen_string_literal: true

require 'mongo'
require 'timeout'
require 'logger'
require 'redis'
require 'webrick'
require 'thread'

NULL_LOGGER = Logger.new('/dev/null')
QUEUE = Queue.new
SERVER = WEBrick::HTTPServer.new(Port: ENV['WEB_SERVER_PORT'])

# healthcheck abstraction
class Status
  STATES = {
    health:   HEALTH = 'health',
    unhealth: UNHEALTH = 'unhealth'
  }.freeze

  attr_accessor :status, :msg

  def self.new_unhealth_status(msg = nil)
    new(status: UNHEALTH, msg: msg)
  end

  def self.new_health_status(msg = nil)
    new(status: HEALTH, msg: msg)
  end

  def initialize(attrs)
    @status = attrs[:status]
    @msg    = attrs[:msg]
  end

  def health?
    status == HEALTH
  end

  def to_s
    "#{@status}: #{@msg}"
  end
end

# base Healthcheck
class Healthcheck
  private

    def status
      raise NotImplemented
    end

    def with_timeout(timeout)
      Timeout.timeout(timeout) { yield }
    end
end

# Mongo healthcheck implementation
class MongoHealthcheck < Healthcheck
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
    Status.new_health_status
  rescue Timeout::Error => e
    Status.new_unhealth_status("Mongo Timeout: #{e.message}")
  rescue => e
    Status.new_unhealth_status("Mongo ERROR: #{e.message}")
  end

  def client
    @client ||= Mongo::Client.new([ENV['MONGO_HOST']], logger: NULL_LOGGER)
  end
end

# Redis healthcheck implementation
class RedisHealthcheck < Healthcheck
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
    Status.new_health_status
  rescue Timeout::Error => e
    Status.new_unhealth_status("Redis Timeout: #{e.message}")
  rescue SocketError, Redis::CannotConnectError => e
    Status.new_unhealth_status("Redis ERROR: #{e.message}")
  end

  def client
    @client ||= Redis.new(url: ENV['REDIS_HOST'])
  end
end

# Healthcheck executable
module Run
  module_function

  def run_healthcheck(service)
    service.new.status
  end

  def run_healthcheck_for(services, wait = ENV['WAIT'].to_i)
    catch(Status::UNHEALTH) do
      services.each do |service|
        status = run_healthcheck(service)
        sleep(wait)
        throw(Status::UNHEALTH, status) unless status.health?
      end
      nil
    end
  end

  def run_healthcheck_in_parallel(services, wait = ENV['WAIT'].to_i)
    services.map do |service|
      Thread.new do
        QUEUE << run_healthcheck(service)
        sleep(wait)
      end
    end.map(&:join)
  end
end

SERVICES = [MongoHealthcheck, RedisHealthcheck].freeze

# HealthcheckRoute
class Route < WEBrick::HTTPServlet::AbstractServlet
  def with_duration
    start_time = Time.now
    yield
    ((Time.now - start_time) * 1e3).to_i
  end
end

# serial route
class HealthcheckRoute < Route
  def do_GET(_, response)
    unhealth_status = nil
    duration = with_duration do
      unhealth_status = Run.run_healthcheck_for(SERVICES)
    end

    response.status = 200
    response['Content-Type'] = 'text/plain'
    msg = status&.to_s || 'WORKING'
    response.body = "#{msg} - #{duration} ms"
  end
end

# parallel route
class ParallelHealthcheckRoute < Route
  def do_GET(_, response)
    duration = with_duration do
      Run.run_healthcheck_in_parallel(SERVICES)
    end

    status = nil
    2.times do
      status = QUEUE.pop
      status = nil if status.health?
    end

    response.status = 200
    response['Content-Type'] = 'text/plain'
    msg = status&.to_s || 'WORKING'
    response.body = "#{msg} - #{duration} ms"
  end
end


trap 'INT' do
  SERVER.shutdown
end
SERVER.mount '/healthcheck', HealthcheckRoute
SERVER.mount '/parallel-healthcheck', ParallelHealthcheckRoute
SERVER.start

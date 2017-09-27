# frozen_string_literal: true

require 'mongo'
require 'timeout'
require 'logger'
require 'redis'
require 'webrick'
require 'concurrent'

NULL_LOGGER = Logger.new('/dev/null')
SERVER = WEBrick::HTTPServer.new(Port: ENV['WEB_SERVER_PORT'])

# healthcheck abstraction
class Status
  HEALTH = 'HEALTH'
  UNHEALTH = 'UNHEALTH'

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
    @status == HEALTH
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
end

# Mongo healthcheck implementation
class MongoHealthcheck < Healthcheck
  def perform
    Timeout.timeout(ENV['MONGO_TIMEOUT'].to_i) { call }
  end

  def call
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
    Timeout.timeout(ENV['REDIS_TIMEOUT'].to_i) { call }
  end

  def call
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

module Util
  module_function

  def with_duration
    start_time = Time.now
    yield
    ((Time.now - start_time) * 1e3).to_i
  end
end

# Healthcheck executable
module Runner
  module_function

  def run_healthcheck(service)
    service.new.status
  end

  def async_run_healthcheck_for(services)
    services.map do |service|
      Concurrent::Future.execute do
        status = nil
        duration = Util.with_duration do
          sleep(ENV['WAIT'].to_i)
          status = run_healthcheck(service)
        end

        [status, duration]
      end
    end
  end

  def run_healthcheck_for(services)
    catch(Status::UNHEALTH) do
      services.each do |service|
        status = run_healthcheck(service)
        sleep(ENV['WAIT'].to_i)
        throw(Status::UNHEALTH, status) unless status.health?
      end
      nil
    end
  end
end

SERVICES = [RedisHealthcheck, MongoHealthcheck].freeze

# serial route
class HealthcheckRoute < WEBrick::HTTPServlet::AbstractServlet
  def do_GET(_, response)
    unhealth_status = nil
    duration = Util.with_duration do
      unhealth_status = Runner.run_healthcheck_for(SERVICES)
    end

    response.status = 200
    response['Content-Type'] = 'text/plain'

    msg = unhealth_status&.to_s || 'WORKING'
    response.body = "#{msg} - #{duration} ms"
  end
end

# parallel route
class ParallelHealthcheckRoute < WEBrick::HTTPServlet::AbstractServlet
  def do_GET(_, response)
    response.status = 200
    response['Content-Type'] = 'text/plain'
    promises = nil

    start_time = Time.now

    req_duration = Util.with_duration do
      promises = Runner.async_run_healthcheck_for(SERVICES)
      # wait promises to finish
      until finish?(promises) do
        give_others_threads_a_chance_to_run

        promises.each do |promise|
          next unless promise.fulfilled?

          status, duration = promise.value
          next if status.health?

          return response.body = "#{status} #{duration} ms"
        end
      end
    end

    return response.body = "WORKING #{req_duration} ms" if everything_ok?(promises)

    log_errors(promises)
    response.body = "ERROR #{req_duration} ms"
    response.status = 500
  end

  private

  # give cpu a chance to process the others threads
  def give_others_threads_a_chance_to_run
    sleep(1/(200*1e3))
  end

  def everything_ok?(promises)
    promises.all?(&:fulfilled?)
  end

  def finish?(promises)
    promises.all? { |w| w.fulfilled? || w.rejected? }
  end

  def log_errors(promises)
    promises.each do |promise|
      next unless promise.rejected?
      SERVER.logger.error(promise.reason)
    end
  end
end

trap 'INT' do
  SERVER.shutdown
end
SERVER.mount '/healthcheck', HealthcheckRoute
SERVER.mount '/parallel-healthcheck', ParallelHealthcheckRoute
SERVER.start
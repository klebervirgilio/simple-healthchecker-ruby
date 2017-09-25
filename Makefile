DC := $(shell command -v docker-compose 2> /dev/null)

default: services-down
	@docker-compose up --remove-orphan -d

start: default

install-docker:
ifndef DC
	@echo '----- "docker-compose" is required. https://docs.docker.com/engine/installation/#supported-platforms -----'
	exit 1
endif

services-down: install-docker
	@docker-compose down

success-scenario: default
	@sleep 1
	@curl http://localhost:4444/healthcheck

parallel-success-scenario: default
	@sleep 1
	@curl http://localhost:4444/parallel-healthcheck

failed-scenario: services-down
	@docker-compose up --remove-orphan -d service
	@sleep 1
	@curl http://localhost:4444/healthcheck

parallel-failed-scenario: services-down
	@docker-compose up --remove-orphan -d service
	@sleep 1
	@curl http://localhost:4444/healthcheck

DC := $(shell command -v docker-compose 2> /dev/null)

default: install-docker
	@docker-compose up --remove-orphan -d

start: default

install-docker:
ifndef DC
	@echo '----- "docker-compose" is required. https://docs.docker.com/engine/installation/#supported-platforms -----'
	exit 1
endif

success_scenario: default
	@sleep 1
	@curl http://localhost:4444/healthcheck

failed_scenario: install-docker
	@docker-compose down
	@docker-compose up --remove-orphan -d service
	@sleep 1
	@curl http://localhost:4444/healthcheck

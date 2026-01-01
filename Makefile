# RMC Genesis Contract - Docker Commands
.PHONY: build test test-ots generate-ots generate-dev shell clean help

# Default target
help:
	@echo "RMC Genesis Contract - Available Commands"
	@echo "=========================================="
	@echo ""
	@echo "Build & Test:"
	@echo "  make build        - Compile all contracts"
	@echo "  make test         - Run all tests"
	@echo "  make test-ots     - Run OTS tests only"
	@echo ""
	@echo "Genesis Generation:"
	@echo "  make generate-ots - Generate OTS genesis allocation"
	@echo "  make generate-dev - Generate full dev genesis"
	@echo ""
	@echo "Development:"
	@echo "  make shell        - Open interactive shell in container"
	@echo "  make clean        - Remove Docker volumes and artifacts"
	@echo ""

# Build contracts
build:
	docker compose run --rm foundry

# Run all tests
test:
	docker compose run --rm test

# Run OTS tests only
test-ots:
	docker compose run --rm test-ots

# Generate OTS genesis
generate-ots:
	docker compose run --rm generate-ots

# Generate dev genesis
generate-dev:
	docker compose run --rm generate-dev

# Interactive shell
shell:
	docker compose run --rm shell

# Clean up
clean:
	docker compose down -v
	rm -rf out cache

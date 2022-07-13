.DEFAULT_GOAL := help
.PHONY: help

help:
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	| sed -n 's/^\(.*\): \(.*\)\(##.*\)/\1\3/p' \
	| column -t  -s '##'

clean: ## Cleans installed bundles
	rm Gemfile.lock

install: ## Installs bundles
	bundle install

update: ## Update bundles
	bundle update

run: ## Serves bundle through jekyll.
	bundle exec jekyll serve
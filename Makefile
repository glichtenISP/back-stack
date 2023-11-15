CROSSPLANE_CLI_VERSION="v1.13.2"
SHELL := /bin/bash

.PHONY: install-crossplane-cli
install-crossplane-cli:
	@if ! command -v crossplane 1> /dev/null 2> /dev/null; then \
    echo "Installing crossplane cli in ${HOME}/.local/bin directory"; \
    cd scripts; \
    export XP_VERSION=${CROSSPLANE_CLI_VERSION} && curl -sL "https://raw.githubusercontent.com/crossplane/crossplane/master/install.sh" | sh && mv crossplane ${HOME}/.local/bin/; \
    cd .. ;\
  elif [ "$(shell crossplane --version)" != "${CROSSPLANE_CLI_VERSION}" ]; then \
    echo "Found crossplane version $(shell crossplane --version)  Installing crossplane version ${CROSSPLANE_CLI_VERSION} in ${HOME}/.local/bin directory instead"; \
    cd scripts; \
    export XP_VERSION=${CROSSPLANE_CLI_VERSION} && curl -sL "https://raw.githubusercontent.com/crossplane/crossplane/master/install.sh" | sh && mv crossplane ${HOME}/.local/bin/; \
    cd .. ;\
  fi

.PHONY: asdf-install
asdf-install:
	-@while read -r line; do \
    linearray=($$line); \
    asdf plugin add $$linearray > /dev/null || true; \
  done < .tool-versions
	@asdf install > /dev/null
	@echo "installed asdf dependencies"

.PHONY: clean
clean:
	@k3d cluster delete backstack > /dev/null || true;
	@k3d registry delete k3d-backstack.localhost 2> /dev/null || true;

.PHONY: up
up: clean install-crossplane-cli asdf-install
	bash local-install.sh

# Setting SHELL to bash allows bash commands to be executed by recipes.
# Options are set to exit when a recipe line exits non-zero or a piped command fails.
SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

.DEFAULT_GOAL:=help

# Go.
GO_VERSION ?= 1.22.3
GO_DIRECTIVE_VERSION ?= 1.22.0
GO_CONTAINER_IMAGE ?= docker.io/library/golang:$(GO_VERSION)

# Get some git stuff for later use
GIT_COMMIT_SHA         ?= $(shell git rev-parse HEAD)
GIT_COMMIT_REF_NAME    ?= $(shell git describe --tags --exact-match 2> /dev/null || git symbolic-ref -q --short HEAD || git rev-parse --short HEAD)
GIT_REMOTE_URL ?= $(shell git config --get remote.origin.url)
GIT_BRANCH ?= $(shell git branch --show-current)

# Use GOPROXY environment variable if set
GOPROXY := $(shell go env GOPROXY)
ifeq ($(GOPROXY),)
GOPROXY := https://proxy.golang.org
endif
export GOPROXY
GOOS ?= $(shell go env GOOS)
GOARCH ?= $(shell go env GOARCH)

# Active module mode, as we use go modules to manage dependencies
export GO111MODULE=on

# This option is for running docker manifest command
export DOCKER_CLI_EXPERIMENTAL := enabled

# kind
CAPI_KIND_CLUSTER_NAME ?= capi-tes

# Directories
ROOT_DIR:=$(shell dirname $(realpath $(firstword $(MAKEFILE_LIST))))
BIN_DIR := bin

# Container image settings
REGISTRY  ?= ghcr.io/capi-samples
CONTROLLER_IMAGE_NAME ?= cluster-api-provider-meta
CONTROLLER_IMG ?= $(REGISTRY)/$(CONTROLLER_IMAGE_NAME)
MANIFESTS_IMAGE_NAME ?= cluster-api-meta-manifests
MANIFESTS_IMG ?= $(REGISTRY)/$(MANIFESTS_IMAGE_NAME)
ARCH ?= $(shell go env GOARCH)
ALL_ARCH = amd64 arm64
TAG ?= dev

# CURL_RETRIES refers to the number of retries to be used by curl when downloading binaries.
CURL_RETRIES = 3

# Allow overriding the imagePullPolicy
PULL_POLICY ?= Always

# ENVTEST_K8S_VERSION refers to the version of kubebuilder assets to be downloaded by envtest binary.
ENVTEST_K8S_VERSION = 1.30.0

# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif

# Set build time variables including version details
LDFLAGS := $(shell hack/version.sh)

OS := $(shell go env GOOS)

.PHONY: all
all: test manager

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)


# Setting SHELL to bash allows bash commands to be executed by recipes.
# Options are set to exit when a recipe line exits non-zero or a piped command fails.
SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

.PHONY: all
all: build

##@ Generate

.PHONY: generate
generate: controller-gen ## Run all code generation
	$(MAKE) generate-manifests generate-go-deepcopy generate-go

.PHONY: generate-manifests
generate-manifests: $(CONTROLLER_GEN) ## Generate WebhookConfiguration, ClusterRole and CustomResourceDefinition objects.
	$(MAKE) clean-generated-yaml SRC_DIRS="./config/crd/bases"
	$(CONTROLLER_GEN) \
		paths=./ \
		paths=./api/... \
		paths=./internal/controller/... \
		crd:crdVersions=v1 \
		webhook \
		rbac:roleName=manager-role \
		output:crd:dir=./config/crd/bases

.PHONY: generate-go-deepcopy
generate-go-deepcopy: $(CONTROLLER_GEN) ## Generate deepcopy go code
	$(MAKE) clean-generated-deepcopy SRC_DIRS="./api"
	$(CONTROLLER_GEN) \
		object:headerFile="hack/boilerplate.go.txt" \
		paths=./api/...

.PHONY: generate-modules
generate-modules: ## Run go mod tidy to ensure modules are up to date
	go mod tidy

.PHONY: generate-go
generate-go: ## Run go code generation
	go generate ./...

##@ Development

.PHONY: fmt
fmt: ## Run go fmt against code.
	go fmt ./...

.PHONY: vet
vet: ## Run go vet against code.
	go vet ./...

.PHONY: lint
lint: golangci-lint ## Run golangci-lint linter
	$(GOLANGCI_LINT) run

.PHONY: lint-fix
lint-fix: golangci-lint ## Run golangci-lint linter and perform fixes
	$(GOLANGCI_LINT) run --fix

.PHONY: run
run: manifests generate fmt vet ## Run a controller from your host.
	go run ./cmd/main.go

##@ Build

.PHONY: manager
manager: ## Build manager binary.
	go build -trimpath -ldflags "$(LDFLAGS)" -o bin/capc-manager github.com/capi-samples/cluster-api-provider-meta

.PHONY: docker-pull-prerequisites
docker-pull-prerequisites:
	docker pull docker.io/docker/dockerfile:1.4
	docker pull $(GO_CONTAINER_IMAGE)
	docker pull gcr.io/distroless/static:latest

.PHONY: docker-build-all
docker-build-all: $(addprefix docker-build-,$(ALL_ARCH)) ## Build docker images for all architectures

docker-build-%:
	$(MAKE) ARCH=$* docker-build

# If you wish to build the manager image targeting other platforms you can use the --platform flag.
# (i.e. docker build --platform linux/arm64). However, you must enable docker buildKit for it.
# More info: https://docs.docker.com/develop/develop-images/build_enhancements/
.PHONY: docker-build
docker-build: docker-pull-prerequisites ## Build docker image with the manager.
	DOCKER_BUILDKIT=1 docker build --build-arg builder_image=$(GO_CONTAINER_IMAGE) --build-arg ARCH=$(ARCH) --build-arg ldflags="$(LDFLAGS)" -t $(CONTROLLER_IMG)-$(ARCH):$(TAG) .

##@ Testing

.PHONY: test
test: generate fmt vet envtest ## Run tests.
	KUBEBUILDER_ASSETS="$(shell $(ENVTEST) use $(ENVTEST_K8S_VERSION) --bin-dir $(LOCALBIN) -p path)" go test $$(go list ./... | grep -v /e2e) -coverprofile cover.out

# Utilize Kind or modify the e2e tests to load the image locally, enabling compatibility with other vendors.
.PHONY: test-e2e  # Run the e2e tests against a Kind k8s instance that is spun up.
test-e2e:
	go test ./test/e2e/ -v -ginkgo.v

.PHONY: kind-cluster
kind-cluster: ## Create a new kind cluster designed for development with Tilt
	hack/kind-with-registry.sh

##@ Release

RELEASE_DIR := out

.PHONY: $(RELEASE_DIR)
$(RELEASE_DIR):
	mkdir -p $(RELEASE_DIR)/

.PHONY: manifest-modification
manifest-modification: # Set the manifest images, pull etc for release. Do this before building the release manifest
	$(MAKE) set-manifest-image MANIFEST_IMG=$(CONTROLLER_IMG) MANIFEST_TAG=$(TAG) TARGET_RESOURCE="$(ROOT_DIR)/config/default/manager_image_patch.yaml"
	$(MAKE) set-manifest-pull-policy TARGET_RESOURCE="$(ROOT_DIR)/config/default/manager_pull_policy.yaml"

.PHONY: release-manifests
release-manifests: $(RELEASE_DIR) kustomize ## Build the manifests to publish with a release
	$(KUSTOMIZE) build config/default > $(RELEASE_DIR)/infrastructure-components.yaml
	cp metadata.yaml $(RELEASE_DIR)/metadata.yaml

.PHONY: release-manifests-airgapped
release-manifests-airgapped: $(RELEASE_DIR) kubectl envsubst  ## Build a CAPI Operator  airgapped comfig map
	$(KUBECTL) create configmap ${TAG} --namespace=capc-system --from-file=components=$(RELEASE_DIR)/infrastructure-components.yaml --from-file=metadata=$(RELEASE_DIR)/metadata.yaml --dry-run=client -o yaml | $(KUBECTL) label -f - --dry-run=client -o yaml --local provider-components=meta > $(RELEASE_DIR)/airgapped-cm.yaml
	cat hack/provider-template.tmpl | TAG=${TAG} $(ENVSUBST) > $(RELEASE_DIR)/provider.yaml

.PHONY: set-manifest-image
set-manifest-image:
	$(info Updating kustomize image patch file for manager resource)
ifeq ($(shell uname -s), Darwin)
	sed -i '' -e 's@image: .*@image: '"${MANIFEST_IMG}:$(MANIFEST_TAG)"'@' ./config/default/manager_image_patch.yaml
else
	sed -i -e 's@image: .*@image: '"${MANIFEST_IMG}:$(MANIFEST_TAG)"'@' ./config/default/manager_image_patch.yaml
endif

.PHONY: set-manifest-pull-policy
set-manifest-pull-policy:
	$(info Updating kustomize pull policy file for manager resource)
ifeq ($(shell uname -s), Darwin)
	sed -i '' -e 's@imagePullPolicy: .*@imagePullPolicy: '"$(PULL_POLICY)"'@' ./config/default/manager_pull_policy.yaml
else
	sed -i -e 's@imagePullPolicy: .*@imagePullPolicy: '"$(PULL_POLICY)"'@' ./config/default/manager_pull_policy.yaml
endif

##@ Deployment

ifndef ignore-not-found
  ignore-not-found = false
endif

.PHONY: install
install: manifests kustomize ## Install CRDs into the K8s cluster specified in ~/.kube/config.
	$(KUSTOMIZE) build config/crd | $(KUBECTL) apply -f -

.PHONY: uninstall
uninstall: manifests kustomize ## Uninstall CRDs from the K8s cluster specified in ~/.kube/config. Call with ignore-not-found=true to ignore resource not found errors during deletion.
	$(KUSTOMIZE) build config/crd | $(KUBECTL) delete --ignore-not-found=$(ignore-not-found) -f -

.PHONY: deploy
deploy: manifests kustomize ## Deploy controller to the K8s cluster specified in ~/.kube/config.
	cd config/manager && $(KUSTOMIZE) edit set image controller=${IMG}
	$(KUSTOMIZE) build config/default | $(KUBECTL) apply -f -

.PHONY: undeploy
undeploy: kustomize ## Undeploy controller from the K8s cluster specified in ~/.kube/config. Call with ignore-not-found=true to ignore resource not found errors during deletion.
	$(KUSTOMIZE) build config/default | $(KUBECTL) delete --ignore-not-found=$(ignore-not-found) -f -

.PHONY: docker-push
docker-push: ## Push docker image with the manager.
	docker push ${CONTROLLER_IMG}-$(ARCH):${TAG}

.PHONY: docker-push-all
docker-push-all: $(addprefix docker-push-,$(ALL_ARCH))  ## Push all the architecture docker images
	$(MAKE) docker-push-manifest

.PHONY: docker-push-manifest
docker-push-manifest: ## Push the multiarch manifest for the docker images
	docker manifest create --amend $(CONTROLLER_IMG):$(TAG) $(shell echo $(ALL_ARCH) | sed -e "s~[^ ]*~$(CONTROLLER_IMG)\-&:$(TAG)~g")
	@for arch in $(ALL_ARCH); do docker manifest annotate --arch $${arch} ${CONTROLLER_IMG}:${TAG} ${CONTROLLER_IMG}-$${arch}:${TAG}; done
	docker manifest push --purge $(CONTROLLER_IMG):$(TAG)

docker-push-%:
	$(MAKE) ARCH=$* docker-push

.PHONY: manifest-image-push
manifest-image-push: flux ## Push the manifests OCI image
	$(FLUX) push artifact oci://$(MANIFESTS_IMG):$(TAG) --path="./out" --ignore-paths="infrastructure-components.yaml,metadata.yaml"  --source="$(GIT_REMOTE_URL)" --revision="$(GIT_BRANCH)@sha1:$(GIT_COMMIT_SHA)"

##@ Clean

.PHONY: clean-generated-yaml
clean-generated-yaml: ## Remove files generated by conversion-gen from the mentioned dirs. Example SRC_DIRS="./api/v1alpha4"
	(IFS=','; for i in $(SRC_DIRS); do find $$i -type f -name '*.yaml' -exec rm -f {} \;; done)

.PHONY: clean-generated-deepcopy
clean-generated-deepcopy: ## Remove files generated by conversion-gen from the mentioned dirs. Example SRC_DIRS="./api/v1alpha4"
	(IFS=','; for i in $(SRC_DIRS); do find $$i -type f -name 'zz_generated.deepcopy*' -exec rm -f {} \;; done)


##@ Dependencies

## Location to install dependencies to
LOCALBIN ?= $(shell pwd)/bin
$(LOCALBIN):
	mkdir -p $(LOCALBIN)

## Tool Binaries
KUBECTL ?= $(LOCALBIN)/kubectl
KUSTOMIZE ?= $(LOCALBIN)/kustomize
ENVSUBST ?= $(LOCALBIN)/envsubst
CONTROLLER_GEN ?= $(LOCALBIN)/controller-gen-$(CONTROLLER_TOOLS_VERSION)
ENVTEST ?= $(LOCALBIN)/setup-envtest-$(ENVTEST_VERSION)
GOLANGCI_LINT = $(LOCALBIN)/golangci-lint-$(GOLANGCI_LINT_VERSION)
FLUX ?= $(LOCALBIN)/flux

## Tool Versions
KUBECTL_VERSION ?= v1.28.2
KUSTOMIZE_VERSION ?= v5.3.0
ENVSUBST_VER ?= v1.4.2
CONTROLLER_TOOLS_VERSION ?= v0.15.0
ENVTEST_VERSION ?= release-0.18
GOLANGCI_LINT_VERSION ?= v1.57.2
FLUX_VERSION ?= 2.3.0

.PHONY: kubectl
kubectl: $(KUBECTL) ## Download kubectl locally if necessary.
$(KUBECTL): $(LOCALBIN)
	test -s $(LOCALBIN)/kubectl && $(LOCALBIN)/kubectl version --client | grep -q $(KUBECTL_VERSION) || \
	curl --retry $(CURL_RETRIES) -fsL https://dl.k8s.io/release/$(KUBECTL_VERSION)/bin/$(GOOS)/$(GOARCH)/kubectl -o $(LOCALBIN)/kubectl && \
	chmod +x $(LOCALBIN)/kubectl

.PHONY: envsubst
envsubst: $(ENVSUBST)
$(ENVSUBST): $(LOCALBIN)
	test -s $(LOCALBIN)/envsubst || GOBIN=$(LOCALBIN) GO111MODULE=on go install github.com/a8m/envsubst/cmd/envsubst@$(ENVSUBST_VER)

.PHONY: flux
flux: $(FLUX) ## Download flux locally if necessary. If wrong version is installed, it will be overwritten.
$(FLUX): $(LOCALBIN)
	test -s $(LOCALBIN)/flux && $(LOCALBIN)/flux version --client | grep -q $(FLUX_VERSION) || \
	( \
		curl -s https://fluxcd.io/install.sh > /tmp/flux-install.sh && \
		chmod +x /tmp/flux-install.sh && \
		FLUX_VERSION=$(FLUX_VERSION) /tmp/flux-install.sh $(LOCALBIN) && \
		rm /tmp/flux-install.sh \
	)

.PHONY: kustomize
kustomize: $(KUSTOMIZE) ## Download kustomize locally if necessary. If wrong version is installed, it will be removed before downloading.
$(KUSTOMIZE): $(LOCALBIN)
	test -s $(LOCALBIN)/kustomize || GOBIN=$(LOCALBIN) GO111MODULE=on go install sigs.k8s.io/kustomize/kustomize/v5@$(KUSTOMIZE_VERSION)

.PHONY: controller-gen
controller-gen: $(CONTROLLER_GEN) ## Download controller-gen locally if necessary.
$(CONTROLLER_GEN): $(LOCALBIN)
	$(call go-install-tool,$(CONTROLLER_GEN),sigs.k8s.io/controller-tools/cmd/controller-gen,$(CONTROLLER_TOOLS_VERSION))

.PHONY: envtest
envtest: $(ENVTEST) ## Download setup-envtest locally if necessary.
$(ENVTEST): $(LOCALBIN)
	$(call go-install-tool,$(ENVTEST),sigs.k8s.io/controller-runtime/tools/setup-envtest,$(ENVTEST_VERSION))

.PHONY: golangci-lint
golangci-lint: $(GOLANGCI_LINT) ## Download golangci-lint locally if necessary.
$(GOLANGCI_LINT): $(LOCALBIN)
	$(call go-install-tool,$(GOLANGCI_LINT),github.com/golangci/golangci-lint/cmd/golangci-lint,${GOLANGCI_LINT_VERSION})

# go-install-tool will 'go install' any package with custom target and name of binary, if it doesn't exist
# $1 - target path with name of binary (ideally with version)
# $2 - package url which can be installed
# $3 - specific version of package
define go-install-tool
@[ -f $(1) ] || { \
set -e; \
package=$(2)@$(3) ;\
echo "Downloading $${package}" ;\
GOBIN=$(LOCALBIN) go install $${package} ;\
mv "$$(echo "$(1)" | sed "s/-$(3)$$//")" $(1) ;\
}
endef

# ==============================================
# Ensure GitHub token is set for Renovate
ifndef RENOVATE_TOKEN
$(error RENOVATE_TOKEN is not set. Please export your GitHub Personal Access Token as RENOVATE_TOKEN)
endif
export RENOVATE_TOKEN

# ==============================================
# Deps
KIND             := kindest/node:v1.33.1
KIND_CLUSTER     := todo-api-cluster
REGISTRY_NAME    := todo-registry
REGISTRY_PORT    := 5000
KIND_CONFIG_FILE := zarf/k8s/dev/kind-config.yaml

MODULE_PATH      := github.com/zaouldyeck/todo-service
IMAGE_NAME       := localhost:5000/todo-service
IMAGE_TAG        := dev
VERSION          := "0.0.1"
TODO_IMAGE		 := $(IMAGE_NAME):$(IMAGE_TAG)
HELM_CHART       := ./chart/todo-service
HELM_RELEASE     := todo
HELM_NAMESPACE   := todo

# ==============================================
# Vendoring Go deps
.PHONY: vendor
vendor:
	@echo ">>> Vendoring Go modules"
	go mod tidy
	go mod vendor

# ==============================================
# Local registry

.PHONY: registry-up registry-down
registry-up:
	@echo ">>> Starting registry $(REGISTRY_NAME) on port $(REGISTRY_PORT)"
	docker run -d --restart=always \
		-p $(REGISTRY_PORT):$(REGISTRY_PORT) \
		--name $(REGISTRY_NAME) registry:2

registry-down:
	@echo ">>> Stopping registry $(REGISTRY_NAME)"
	docker rm -f $(REGISTRY_NAME) || true

# ==============================================
# Kind config & cluster

.PHONY: kind-config kind-up kind-down

kind-config:
	@echo ">>> Rendering Kind config to $(KIND_CONFIG_FILE)"
	@mkdir -p $(dir $(KIND_CONFIG_FILE))
	@printf '%s\n' \
		'kind: Cluster' \
		'apiVersion: kind.x-k8s.io/v1alpha4' \
		'containerdConfigPatches:' \
		'- |-' \
		'  [plugins."io.containerd.grpc.v1.cri".registry.mirrors."localhost:$(REGISTRY_PORT)"]' \
		'    endpoint = ["http://$(REGISTRY_NAME):$(REGISTRY_PORT)"]' \
		'nodes:' \
		'- role: control-plane' \
	> $(KIND_CONFIG_FILE)

kind-up: registry-up kind-config
	@echo ">>> Creating Kind cluster $(KIND_CLUSTER)"
	kind create cluster \
		--name $(KIND_CLUSTER) \
		--image $(KIND) \
		--config $(KIND_CONFIG_FILE)
	@docker network connect kind $(REGISTRY_NAME) || true
	@echo ">>> Applying registry ConfigMap in namespace $(HELM_NAMESPACE)"
	kubectl create namespace $(HELM_NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	@printf '%s\n' \
		'apiVersion: v1' \
		'kind: ConfigMap' \
		'metadata:' \
		'  name: local-registry-hosting' \
		'  namespace: $(HELM_NAMESPACE)' \
		'data:' \
		'  localRegistryHosting.v1: |' \
		'    host: "localhost:$(REGISTRY_PORT)"' \
		'    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"' \
	| kubectl apply -f -

kind-down:
	@echo ">>> Deleting Kind cluster $(KIND_CLUSTER)"
	kind delete cluster --name $(KIND_CLUSTER)
	$(MAKE) registry-down

# ==============================================
# Docker image build & push

.PHONY: image-build image-push

image-build: vendor
	@echo ">>> Building image $(IMAGE_NAME):$(IMAGE_TAG)"
	docker build \
		--build-arg APP_VERSION=$(VERSION) \
		--build-arg BUILD_REF=$(VERSION) \
		--build-arg BUILD_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ") \
		-t $(TODO_IMAGE) \
		-f Dockerfile .

image-push: image-build
	@echo ">>> Pushing image"
	docker push $(TODO_IMAGE)

# ==============================================
# Scaffold Helm chart if missing

.PHONY: chart-init

chart-init:
	@echo ">>> Ensuring Helm chart at $(HELM_CHART)"
	@if [ ! -d "$(HELM_CHART)" ]; then \
		mkdir -p $(dir $(HELM_CHART)); \
		echo ">>> Helm chart not found; creating at $(HELM_CHART)"; \
		helm create $(HELM_CHART); \
	fi

# ==============================================
# Helm deploy
.PHONY: helm-install helm-delete
helm-install: chart-init image-push kind-up
	@echo ">>> Deploying Helm release $(HELM_RELEASE)"
	helm upgrade --install $(HELM_RELEASE) $(HELM_CHART) \
		--namespace $(HELM_NAMESPACE) \
		--set image.repository=$(IMAGE_NAME) \
		--set image.tag=$(IMAGE_TAG)

helm-delete:
	@echo ">>> Uninstalling Helm release $(HELM_RELEASE)"
	helm uninstall $(HELM_RELEASE) --namespace $(HELM_NAMESPACE)


# ==============================================
# Renovate CLI installation

.PHONY: install-renovate-cli

install-renovate-cli:
	@echo ">>> Installing Renovate CLI globally"
	npm install -g renovate

# ==============================================
# Renovate config

.PHONY: renovate-config

renovate-config:
	@echo ">>> Generating renovate.json"
	@printf '%s\n' \
		'{' \
		'  "extends": ["config:base"],' \
		'  "packageRules": [' \
		'    {' \
		'      "managers": ["gomod"],' \
		'      "automerge": true' \
		'    },' \
		'    {' \
		'      "matchPaths": ["Dockerfile"],' \
		'      "matchDatasources": ["docker"],' \
		'      "automerge": true' \
		'    }' \
		'  ]' \
		'}' \
	> renovate.json

# ==============================================
# Renovate

.PHONY: renovate

renovate: install-renovate-cli renovate-config
	@echo ">>> Running Renovate"
	renovate \
	  --token "$(RENOVATE_TOKEN)" \
	  --autodiscover \
	  --autodiscover-filter="/zaouldyeck/todo-service"

# ==============================================
# Full bootstrap: from scratch through Renovate

.PHONY: bootstrap

bootstrap: kind-down bootstrap-start renovate
	@echo ">>> Full bootstrap complete"

.PHONY: bootstrap-start

bootstrap-start: kind-up chart-init image-build image-push helm-install install-renovate-cli renovate-config
	@echo ">>> Initial setup and deploy complete"

# ==============================================
# Convenience aliases

.PHONY: dev-up dev-down deploy

dev-up: bootstrap

deploy: helm-install

dev-down: helm-delete kind-down

# ==============================================
# Status helpers

dev-status-all:
	@echo ">>> Cluster status"
	kubectl get nodes -o wide
	kubectl get svc -o wide
	kubectl get pods -o wide --all-namespaces

dev-status:
	@echo ">>> Watching pods"
	watch -n 2 kubectl get pods -o wide --all-namespaces

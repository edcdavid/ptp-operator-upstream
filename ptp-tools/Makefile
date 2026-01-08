LOCALBIN ?= $(shell pwd)/../bin
$(LOCALBIN):
	mkdir -p $(LOCALBIN)/x86_64/

# Allow PLATFORM to be overridden via environment variable
# If not provided, auto-discover the platform
ifndef PLATFORM
OS := $(shell uname -s | tr '[:upper:]' '[:lower:]')
ARCH := $(shell uname -m)

# Normalize architecture names
ifeq ($(ARCH),x86_64)
  ARCH := amd64
endif
ifeq ($(ARCH),aarch64)
  ARCH := arm64
endif

PLATFORM := $(OS)/$(ARCH)
endif

## Tool Binaries
KUSTOMIZE ?= $(LOCALBIN)/kustomize

IMG_PREFIX ?= quay.io/<your user id here>/<your image name>

VALUES = lptpd cep ptpop krp openvswitch prometheus

podman-buildall: $(foreach v, $(VALUES), podman-build-$(v))

podman-build-%:
	@echo "Platform: $(PLATFORM)"
	$(MAKE) clean-image VAR=$*;
	$(MAKE) build-image VAR=$*

podman-pushall: $(foreach v, $(VALUES), podman-push-$(v))

podman-push-%:
	podman manifest push ${IMG_PREFIX}:$*

build-image:
	podman manifest create ${IMG_PREFIX}:$(VAR)
	# For ptpop, get commit hash and remote URL from parent git repository
ifeq ($(VAR),ptpop)
	$(eval COMMIT_HASH_VAL := $(if $(COMMIT_HASH),$(COMMIT_HASH),$(shell cd .. && git rev-parse HEAD 2>/dev/null || echo "unknown")))
	$(eval GIT_REMOTE_URL_VAL := $(if $(GIT_REMOTE_URL),$(GIT_REMOTE_URL),$(shell cd .. && git config --get remote.origin.url 2>/dev/null | sed 's/\.git$$//' | sed 's|git@github.com:|https://github.com/|' || echo "https://github.com/k8snetworkplumbingwg/ptp-operator")))
	@echo "Building ptpop with COMMIT_HASH=$(COMMIT_HASH_VAL) from $(GIT_REMOTE_URL_VAL)"
	podman build --no-cache --platform $(PLATFORM) \
		--build-arg COMMIT_HASH=$(COMMIT_HASH_VAL) \
		--build-arg GIT_REMOTE_URL=$(GIT_REMOTE_URL_VAL) \
		-f Dockerfile.$(VAR) --manifest ${IMG_PREFIX}:$(VAR) ..
else ifeq ($(VAR),lptpd)
	@echo "Extracting commit hash for lptpd from builder stage..."
	$(eval COMMIT_HASH_VAL := $(if $(COMMIT_HASH),$(COMMIT_HASH),$(shell podman build --platform $(PLATFORM) -f Dockerfile.$(VAR) --target builder .. 2>&1 | grep -E '^###COMMIT_HASH###[a-f0-9]+###COMMIT_HASH###$$' | sed -E 's/^###COMMIT_HASH###([a-f0-9]+)###COMMIT_HASH###$$/\1/' | head -1 || echo "unknown")))
	@echo "Building lptpd with COMMIT_HASH=$(COMMIT_HASH_VAL)"
	podman build --no-cache --platform $(PLATFORM) --build-arg COMMIT_HASH=$(COMMIT_HASH_VAL) -f Dockerfile.$(VAR) --manifest ${IMG_PREFIX}:$(VAR) ..
else ifeq ($(VAR),cep)
	@echo "Extracting commit hash for cep from builder stage..."
	$(eval COMMIT_HASH_VAL := $(if $(COMMIT_HASH),$(COMMIT_HASH),$(shell podman build --platform $(PLATFORM) -f Dockerfile.$(VAR) --target builder .. 2>&1 | grep -E '^###COMMIT_HASH###[a-f0-9]+###COMMIT_HASH###$$' | sed -E 's/^###COMMIT_HASH###([a-f0-9]+)###COMMIT_HASH###$$/\1/' | head -1 || echo "unknown")))
	@echo "Building cep with COMMIT_HASH=$(COMMIT_HASH_VAL)"
	podman build --no-cache --platform $(PLATFORM) --build-arg COMMIT_HASH=$(COMMIT_HASH_VAL) -f Dockerfile.$(VAR) --manifest ${IMG_PREFIX}:$(VAR) ..
else ifeq ($(VAR),krp)
	@echo "Extracting commit hash for krp from builder stage..."
	$(eval COMMIT_HASH_VAL := $(if $(COMMIT_HASH),$(COMMIT_HASH),$(shell podman build --platform $(PLATFORM) -f Dockerfile.$(VAR) --target builder .. 2>&1 | grep -E '^###COMMIT_HASH###[a-f0-9]+###COMMIT_HASH###$$' | sed -E 's/^###COMMIT_HASH###([a-f0-9]+)###COMMIT_HASH###$$/\1/' | head -1 || echo "unknown")))
	@echo "Building krp with COMMIT_HASH=$(COMMIT_HASH_VAL)"
	podman build --no-cache --platform $(PLATFORM) --build-arg COMMIT_HASH=$(COMMIT_HASH_VAL) -f Dockerfile.$(VAR) --manifest ${IMG_PREFIX}:$(VAR) ..
else
	$(eval BUILD_ARGS := $(if $(COMMIT_HASH),--build-arg COMMIT_HASH=$(COMMIT_HASH),))
	podman build --no-cache --platform $(PLATFORM) $(BUILD_ARGS) -f Dockerfile.$(VAR) --manifest ${IMG_PREFIX}:$(VAR) ..
endif

clean-image:
	podman image rm ${IMG_PREFIX}:$(VAR) || true
	podman manifest rm ${IMG_PREFIX}:$(VAR) || true

podman-clean-%:
	podman manifest rm ${IMG_PREFIX}:$* || true

podman-cleanall: $(foreach v, $(VALUES), podman-clean-$(v))

deploy-all: 
	./scripts/customize-env.sh ${IMG_PREFIX} ../config/manager
	cd ../config/manager && $(KUSTOMIZE) edit set image controller=${IMG_PREFIX}:ptpop
	$(KUSTOMIZE) build ../config/default | kubectl apply -f -
	$(KUSTOMIZE) build ../config/custom | kubectl apply -f -
	kubectl patch ptpoperatorconfig default -nopenshift-ptp --type=merge --patch '{"spec": {"ptpEventConfig": {"enableEventPublisher": true, "transportHost": "http://ptp-event-publisher-service-NODE_NAME.openshift-ptp.svc.cluster.local:9043", "storageType": "local-sc"}, "daemonNodeSelector": {"node-role.kubernetes.io/worker": ""}}}'

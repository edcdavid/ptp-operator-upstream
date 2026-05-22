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

VALUES = lptpd cep ptpop krp openvswitch prometheus ptpmg debug

podman-buildall: $(foreach v, $(VALUES), podman-build-$(v))

podman-build-%:
	@echo "Platform: $(PLATFORM)"
	podman image rm ${IMG_PREFIX}:$* || true
	podman build --no-cache --platform $(PLATFORM) -t ${IMG_PREFIX}:$* -f Dockerfile.$* ..

podman-pushall: $(foreach v, $(VALUES), podman-push-$(v))

podman-push-%:
	podman push ${IMG_PREFIX}:$* docker://${IMG_PREFIX}:$*

# Build then immediately push each image sequentially.
# Using -t (plain image tag) instead of --manifest avoids podman 5.x bugs
# where manifest-list entries become unresolvable in local storage.
podman-buildpushall: $(foreach v, $(VALUES), podman-buildpush-$(v))

podman-buildpush-%:
	@echo "Platform: $(PLATFORM)"
	podman image rm ${IMG_PREFIX}:$* || true
	podman build --no-cache --platform $(PLATFORM) -t ${IMG_PREFIX}:$* -f Dockerfile.$* ..
	podman push ${IMG_PREFIX}:$* docker://${IMG_PREFIX}:$*

podman-clean-%:
	podman image rm ${IMG_PREFIX}:$* || true

podman-cleanall: $(foreach v, $(VALUES), podman-clean-$(v))

deploy-all: 
	./scripts/customize-env.sh ${IMG_PREFIX} ../config/manager
	cd ../config/manager && $(KUSTOMIZE) edit set image controller=${IMG_PREFIX}:ptpop
	$(KUSTOMIZE) build ../config/default | kubectl apply -f -
	$(KUSTOMIZE) build ../config/custom | kubectl apply -f -
	kubectl patch ptpoperatorconfig default -nopenshift-ptp --type=merge --patch '{"spec": {"ptpEventConfig": {"enableEventPublisher": true, "transportHost": "http://ptp-event-publisher-service-NODE_NAME.openshift-ptp.svc.cluster.local:9043", "storageType": "local-sc"}, "daemonNodeSelector": {"node-role.kubernetes.io/worker": ""}}}'

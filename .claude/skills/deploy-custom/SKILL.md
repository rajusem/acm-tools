# Deploy Custom Image

Build, push, and deploy a custom MCO or MCOA image to the cluster.

## Arguments

The user should specify:
- Which image: `mco`, `mcoa`, or `both`
- Optionally: a specific tag (otherwise auto-increment from `image-override.json`)

## Workflow

### Step 1: Determine next tag

Read `image-override.json` to find current tags. Auto-increment the tag for the requested image(s).
MCH uses `imagePullPolicy: IfNotPresent` — NEVER reuse an existing tag.

### Step 2: Read build config

All build settings come from `config.sh` (overridable via environment variables):

- `MCO_REPO_DIR` — MCO source repo (default: `../multicluster-observability-operator` relative to acm-tools)
- `MCOA_REPO_DIR` — MCOA source repo (default: `../multicluster-observability-addon` relative to acm-tools)
- `MCO_DOCKERFILE` — MCO Dockerfile path within repo (default: `operators/multiclusterobservability/Dockerfile.local`)
- `MCOA_DOCKERFILE` — MCOA Dockerfile path within repo (default: `Dockerfile`)
- `CONTAINER_ENGINE` — podman or docker (auto-detected)
- `BUILD_PLATFORM` — target platform (default: `linux/amd64`)
- `ACM_TOOLS_REGISTRY` — image registry (default: `quay.io/rzalavad`)
- `MCO_IMAGE_NAME` — MCO image name (default: `multicluster-observability-operator`)
- `MCOA_IMAGE_NAME` — MCOA image name (default: `multicluster-observability-addon`)

Verify repo directories exist before building. If not found, STOP and tell the user to set the path in `config.sh` or via environment variable.

### Step 3: Build image(s)

```bash
# MCO:
$CONTAINER_ENGINE build --platform $BUILD_PLATFORM --no-cache \
  -t $ACM_TOOLS_REGISTRY/$MCO_IMAGE_NAME:<tag> \
  -f $MCO_DOCKERFILE $MCO_REPO_DIR

# MCOA:
$CONTAINER_ENGINE build --platform $BUILD_PLATFORM --no-cache \
  -t $ACM_TOOLS_REGISTRY/$MCOA_IMAGE_NAME:<tag> \
  -f $MCOA_DOCKERFILE $MCOA_REPO_DIR
```

MCOA requires `--no-cache` to avoid cached arm64 layers.

### Step 4: Push image(s)

```bash
$CONTAINER_ENGINE push $ACM_TOOLS_REGISTRY/$MCO_IMAGE_NAME:<tag>
$CONTAINER_ENGINE push $ACM_TOOLS_REGISTRY/$MCOA_IMAGE_NAME:<tag>
```

### Step 5: Update image-override.json

Update the `image-tag` field for the built image(s) in `image-override.json`.

### Step 6: Apply override

```bash
bin/image-override apply
```

### Step 7: Patch mch-image-manifest for MCOA

MCO reads the MCOA image from the `mch-image-manifest-*` ConfigMap in `open-cluster-management`, NOT from the `image-override` ConfigMap. Patch it directly:

```bash
MANIFEST_CM=$(oc --context=hub get configmap -n open-cluster-management --no-headers | awk '/^mch-image-manifest/{print $1}' | tail -1)
oc --context=hub patch configmap "$MANIFEST_CM" -n open-cluster-management --type merge \
  -p "{\"data\":{\"multicluster_observability_addon\":\"$ACM_TOOLS_REGISTRY/$MCOA_IMAGE_NAME:<tag>\"}}"
```

### Step 8: Handle MCH Pending state

If MCH is in `Pending` state, it won't reconcile image overrides to deployments. Patch the MCO deployment directly:

```bash
CURRENT_IMAGE=$(oc --context=hub get deployment multicluster-observability-operator -n open-cluster-management \
  -o jsonpath='{.spec.template.spec.containers[0].image}')
EXPECTED_IMAGE="$ACM_TOOLS_REGISTRY/$MCO_IMAGE_NAME:<tag>"

if [[ "$CURRENT_IMAGE" != "$EXPECTED_IMAGE" ]]; then
  oc --context=hub set image deployment/multicluster-observability-operator \
    -n open-cluster-management multicluster-observability-operator="$EXPECTED_IMAGE"
fi
```

### Step 9: Verify deployment

Wait up to 120s for the operator/addon pod to restart with the new image:

```bash
# For MCO:
oc --context=hub get pod -n open-cluster-management -l name=multicluster-observability-operator -o jsonpath='{.items[0].spec.containers[0].image}'

# For MCOA:
oc --context=hub get pod -n open-cluster-management-observability -l app=multicluster-observability-addon-manager -o jsonpath='{.items[0].spec.containers[0].image}'
```

Confirm the pod is running the new tag. If it doesn't match after 120s, warn the user.

## Important notes

- Always build with `--platform $BUILD_PLATFORM` (OpenShift runs on AMD64 nodes)
- MCOA is deployed BY MCO — after applying image override, MCO needs to reconcile to update the MCOA deployment
- MCO reads MCOA image from `mch-image-manifest-*` ConfigMap, not from the `image-override` ConfigMap — always patch both
- If MCO is not installed yet, run `bin/setup-observability install` first, then apply override
- Build failures should be reported with the full error output
- Users with non-standard repo layouts should set `MCO_REPO_DIR` and `MCOA_REPO_DIR` in `config.sh` or export them before running

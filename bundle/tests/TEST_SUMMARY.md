# PTP Operator Bundle Mirroring Test Summary

## Overview

This test validates that the `operators.openshift.io/must-gather-image` annotation in the PTP Operator CSV ensures the must-gather image is included when mirroring operator images to a private registry.

## Test Architecture

The test uses a **two-registry architecture** to simulate real-world image mirroring:

```
┏━━━━━━━━━━━━━━━━━━━━━━━┓         ┏━━━━━━━━━━━━━━━━━━━━━━┓
┃  SOURCE REGISTRY      ┃         ┃  TARGET REGISTRY     ┃
┃  (Port 5000)          ┃         ┃  (Port 5001)         ┃
┃                       ┃         ┃                      ┃
┃  Simulates:           ┃  ════>  ┃  Simulates:          ┃
┃  - Public registry    ┃ Mirror  ┃  - Private registry  ┃
┃  - Connected env      ┃         ┃  - Disconnected env  ┃
┗━━━━━━━━━━━━━━━━━━━━━━━┛         ┗━━━━━━━━━━━━━━━━━━━━━━┛
```

## Test Execution Flow

### Phase 1: Build and Push to Source Registry

1. ✅ Verify CSV contains `operators.openshift.io/must-gather-image` annotation
2. ✅ Validate bundle directory structure
3. ✅ Start source registry container (podman)
4. ✅ Build operator bundle OCI image
5. ✅ Push bundle image to source registry
6. ✅ Extract CSV from bundle and verify annotation

### Phase 2: Mirror to Target Registry

7. ✅ Start target registry container (podman)
8. ✅ Pull bundle from source registry
9. ✅ Push bundle to target registry
10. ✅ Mirror must-gather image to target registry
11. ✅ Verify both images in target registry

### Phase 3: Verification and Reporting

12. ✅ List all images in target registry
13. ✅ Generate image mapping documentation
14. ✅ Produce comprehensive test report
15. ✅ Automatic cleanup of both registries

## What Gets Verified

| Verification | Description |
|--------------|-------------|
| **CSV Annotation** | Confirms annotation is present with correct image reference |
| **Bundle Build** | Validates bundle can be built as OCI image |
| **Source Push** | Tests bundle can be pushed to a registry |
| **Mirror Operation** | Demonstrates pulling from source and pushing to target |
| **Must-Gather Inclusion** | Shows must-gather image is mirrored based on CSV annotation |
| **Target Registry** | Lists all mirrored images in the target registry |

## Images in Target Registry After Test

After successful execution, the target registry (port 5001) contains:

```
Repository: ptp-operator-bundle
  - localhost:5001/ptp-operator-bundle:test

Repository: openshift4/ptp-must-gather-rhel9
  - localhost:5001/openshift4/ptp-must-gather-rhel9:4.21
```

## Real-World Mirroring Workflow

This test simulates what happens when using `oc-mirror` in production:

```bash
# Administrator runs oc-mirror
$ oc-mirror --config=imageset-config.yaml docker://private-registry.company.com

# oc-mirror process:
1. Reads operator catalog
2. Parses each operator bundle
3. Extracts CSV from bundle
4. Finds operators.openshift.io/must-gather-image annotation
5. Adds must-gather image to mirror list
6. Mirrors operator images + must-gather image together
```

## Key Benefits Demonstrated

1. **Automatic Inclusion**: Must-gather image is automatically included via annotation
2. **No Manual Steps**: No need to manually identify and mirror debugging images
3. **Complete Functionality**: All operator and debugging tools available in disconnected environment
4. **Validated Workflow**: Test proves the annotation works as expected

## Running the Test

```bash
cd bundle/tests
./test_must_gather_mirroring.sh
```

**Prerequisites:**
- podman installed
- Ports 5000 and 5001 available
- Internet connection for pulling base images

## Test Output

The test provides:
- Color-coded progress logging
- Phase-by-phase execution status
- List of images in target registry
- Image mapping documentation
- Comprehensive test report
- Automatic cleanup

## Success Criteria

✅ Bundle builds successfully  
✅ Source registry accessible  
✅ Bundle pushes to source  
✅ Target registry accessible  
✅ Bundle mirrors to target  
✅ Must-gather mirrors to target  
✅ All images listed in target registry  
✅ CSV annotation verified in bundle  

## Conclusion

This integration test validates that the `operators.openshift.io/must-gather-image` annotation in the PTP Operator CSV works correctly to ensure the must-gather debugging image is included when mirroring operator images to a private registry in disconnected environments.



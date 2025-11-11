package apply

import (
	"context"
	"log"

	"github.com/pkg/errors"

	uns "k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

// MergeMetadataForUpdate merges the read-only fields of metadata.
// This is to be able to do a a meaningful comparison in apply,
// since objects created on runtime do not have these fields populated.
func MergeMetadataForUpdate(current, updated *uns.Unstructured) error {
	updated.SetCreationTimestamp(current.GetCreationTimestamp())
	updated.SetSelfLink(current.GetSelfLink())
	updated.SetGeneration(current.GetGeneration())
	updated.SetUID(current.GetUID())
	updated.SetResourceVersion(current.GetResourceVersion())

	mergeAnnotations(current, updated)
	mergeLabels(current, updated)

	return nil
}

// MergeObjectForUpdate prepares a "desired" object to be updated.
// Some objects, such as Deployments and Services require
// some semantic-aware updates
func MergeObjectForUpdate(ctx context.Context, current, updated *uns.Unstructured) error {
	if err := MergeDeploymentForUpdate(current, updated); err != nil {
		return err
	}

	if err := MergeDaemonSetForUpdate(ctx, current, updated); err != nil {
		return err
	}

	if err := MergeServiceForUpdate(current, updated); err != nil {
		return err
	}

	if err := MergeServiceAccountForUpdate(current, updated); err != nil {
		return err
	}

	// For all object types, merge metadata.
	// Run this last, in case any of the more specific merge logic has
	// changed "updated"
	MergeMetadataForUpdate(current, updated)

	return nil
}

const (
	deploymentRevisionAnnotation = "deployment.kubernetes.io/revision"
)

// MergeDeploymentForUpdate updates Deployment objects.
// We merge annotations, keeping ours except the Deployment Revision annotation.
func MergeDeploymentForUpdate(current, updated *uns.Unstructured) error {
	gvk := updated.GroupVersionKind()
	if gvk.Group == "apps" && gvk.Kind == "Deployment" {

		// Copy over the revision annotation from current up to updated
		// otherwise, updated would win, and this annotation is "special" and
		// needs to be preserved
		curAnnotations := current.GetAnnotations()
		updatedAnnotations := updated.GetAnnotations()
		if updatedAnnotations == nil {
			updatedAnnotations = map[string]string{}
		}

		anno, ok := curAnnotations[deploymentRevisionAnnotation]
		if ok {
			updatedAnnotations[deploymentRevisionAnnotation] = anno
		}

		updated.SetAnnotations(updatedAnnotations)
	}

	return nil
}

// MergeDaemonSetForUpdate merges DaemonSet updates using context to determine controller:
// For linuxptp-daemon DaemonSet, it merges non-security and security resources separately.
//
// Non-security resources (base volumes, annotations, mounts) always come from updated.
// Security resources (volumes/annotations/mounts ending with -ptpconfig-sec):
//   - If PtpConfigController: use security from updated (source of truth for security)
//   - If PtpOperatorConfigController: preserve security from current (doesn't manage security)
//
// This works because:
//   - PtpConfig gets current, strips security, adds new security, applies with context
//   - PtpOperatorConfig renders from template (no security), applies with context
//   - Context explicitly tells merge which controller is reconciling
func MergeDaemonSetForUpdate(ctx context.Context, current, updated *uns.Unstructured) error {
	gvk := updated.GroupVersionKind()
	if gvk.Group == "apps" && gvk.Kind == "DaemonSet" {
		// Only apply to linuxptp-daemon DaemonSet
		if updated.GetName() != "linuxptp-daemon" {
			return nil
		}

		// Check which controller is performing the update
		controllerName, _ := ctx.Value(ControllerNameKey).(string)
		isPtpConfigController := (controllerName == PtpConfigController)

		// Merge volumes, annotations, and mounts
		if err := mergeSecurityVolumes(current, updated, isPtpConfigController); err != nil {
			return err
		}

		if err := mergeSecurityAnnotations(current, updated, isPtpConfigController); err != nil {
			return err
		}

		if err := mergeSecurityVolumeMounts(current, updated, isPtpConfigController); err != nil {
			return err
		}
	}

	return nil
}

// mergeSecurityVolumes merges volumes based on which controller is reconciling:
// - PtpConfigController: use security volumes from updated (source of truth)
// - PtpOperatorConfigController: preserve security volumes from current
func mergeSecurityVolumes(current, updated *uns.Unstructured, isPtpConfigController bool) error {
	currentVolumes, found, err := uns.NestedSlice(current.Object, "spec", "template", "spec", "volumes")
	if err != nil || !found {
		currentVolumes = []interface{}{}
	}

	updatedVolumes, found, err := uns.NestedSlice(updated.Object, "spec", "template", "spec", "volumes")
	if err != nil {
		return err
	}
	if !found {
		updatedVolumes = []interface{}{}
	}

	// Extract security volumes from current
	var currentSecurityVolumes []interface{}
	for _, vol := range currentVolumes {
		volMap, ok := vol.(map[string]interface{})
		if !ok {
			continue
		}
		name, ok := volMap["name"].(string)
		if !ok {
			continue
		}
		// Security volumes end with "-ptpconfig-sec"
		if len(name) >= 14 && name[len(name)-14:] == "-ptpconfig-sec" {
			currentSecurityVolumes = append(currentSecurityVolumes, vol)
		}
	}

	// Extract non-security and security volumes from updated
	var nonSecurityVolumes []interface{}
	var updatedSecurityVolumes []interface{}

	for _, vol := range updatedVolumes {
		volMap, ok := vol.(map[string]interface{})
		if !ok {
			nonSecurityVolumes = append(nonSecurityVolumes, vol)
			continue
		}
		name, ok := volMap["name"].(string)
		if !ok {
			nonSecurityVolumes = append(nonSecurityVolumes, vol)
			continue
		}

		// Check if it's a security volume (ends with "-ptpconfig-sec")
		if len(name) >= 14 && name[len(name)-14:] == "-ptpconfig-sec" {
			updatedSecurityVolumes = append(updatedSecurityVolumes, vol)
		} else {
			nonSecurityVolumes = append(nonSecurityVolumes, vol)
		}
	}

	// Determine which security volumes to use based on controller
	var securityVolumes []interface{}
	if isPtpConfigController {
		// PtpConfig is source of truth for security - use updated (even if empty)
		log.Printf("MergeDaemonSet: PtpConfig reconciling, using %d security volume(s) from updated", len(updatedSecurityVolumes))
		securityVolumes = updatedSecurityVolumes
	} else {
		// PtpOperatorConfig doesn't manage security - preserve from current
		log.Printf("MergeDaemonSet: PtpOperatorConfig reconciling, preserving %d security volume(s) from current", len(currentSecurityVolumes))
		securityVolumes = currentSecurityVolumes
	}

	// Build merged volumes: non-security from updated + security (from updated or current)
	mergedVolumes := append(nonSecurityVolumes, securityVolumes...)

	return uns.SetNestedSlice(updated.Object, mergedVolumes, "spec", "template", "spec", "volumes")
}

// mergeSecurityAnnotations merges annotations based on which controller is reconciling:
// - PtpConfigController: use security annotations from updated
// - PtpOperatorConfigController: preserve security annotations from current
func mergeSecurityAnnotations(current, updated *uns.Unstructured, isPtpConfigController bool) error {
	currentAnnotations, found, err := uns.NestedStringMap(current.Object, "spec", "template", "metadata", "annotations")
	if err != nil || !found {
		currentAnnotations = make(map[string]string)
	}

	updatedAnnotations, found, err := uns.NestedStringMap(updated.Object, "spec", "template", "metadata", "annotations")
	if err != nil {
		return err
	}
	if !found {
		updatedAnnotations = make(map[string]string)
	}

	// Extract security annotations from current
	prefix := "ptp.openshift.io/secret-hash-"
	currentSecurityAnnotations := make(map[string]string)

	for k, v := range currentAnnotations {
		if len(k) > len(prefix) && k[:len(prefix)] == prefix {
			currentSecurityAnnotations[k] = v
		}
	}

	// Determine which security annotations to use based on controller
	if isPtpConfigController {
		// PtpConfig is source of truth for security - use updated (even if empty)
		log.Printf("MergeDaemonSet: PtpConfig reconciling, using security annotations from updated")
		// updatedAnnotations already has the new values, nothing to do
	} else {
		// PtpOperatorConfig doesn't manage security - preserve from current
		log.Printf("MergeDaemonSet: PtpOperatorConfig reconciling, preserving security annotations from current")
		// Preserve current security annotations
		for k, v := range currentSecurityAnnotations {
			updatedAnnotations[k] = v
		}
	}

	return uns.SetNestedStringMap(updated.Object, updatedAnnotations, "spec", "template", "metadata", "annotations")
}

// mergeSecurityVolumeMounts merges volume mounts based on which controller is reconciling:
// - PtpConfigController: use security mounts from updated
// - PtpOperatorConfigController: preserve security mounts from current
func mergeSecurityVolumeMounts(current, updated *uns.Unstructured, isPtpConfigController bool) error {
	currentContainers, found, err := uns.NestedSlice(current.Object, "spec", "template", "spec", "containers")
	if err != nil || !found {
		return err
	}

	updatedContainers, found, err := uns.NestedSlice(updated.Object, "spec", "template", "spec", "containers")
	if err != nil || !found {
		return err
	}

	// Find security mounts in current linuxptp-daemon-container
	var currentSecurityMounts []interface{}
	for _, cont := range currentContainers {
		contMap, ok := cont.(map[string]interface{})
		if !ok {
			continue
		}
		if name, ok := contMap["name"].(string); ok && name == "linuxptp-daemon-container" {
			mounts, found, err := uns.NestedSlice(contMap, "volumeMounts")
			if err != nil || !found {
				break
			}
			for _, mount := range mounts {
				mountMap, ok := mount.(map[string]interface{})
				if !ok {
					continue
				}
				if mountName, ok := mountMap["name"].(string); ok {
					if len(mountName) >= 14 && mountName[len(mountName)-14:] == "-ptpconfig-sec" {
						currentSecurityMounts = append(currentSecurityMounts, mount)
					}
				}
			}
			break
		}
	}

	// Find security mounts in updated linuxptp-daemon-container
	var updatedSecurityMounts []interface{}
	for _, cont := range updatedContainers {
		contMap, ok := cont.(map[string]interface{})
		if !ok {
			continue
		}
		if name, ok := contMap["name"].(string); ok && name == "linuxptp-daemon-container" {
			mounts, found, err := uns.NestedSlice(contMap, "volumeMounts")
			if err != nil || !found {
				break
			}
			for _, mount := range mounts {
				mountMap, ok := mount.(map[string]interface{})
				if !ok {
					continue
				}
				if mountName, ok := mountMap["name"].(string); ok {
					if len(mountName) >= 14 && mountName[len(mountName)-14:] == "-ptpconfig-sec" {
						updatedSecurityMounts = append(updatedSecurityMounts, mount)
					}
				}
			}
			break
		}
	}

	// Determine which security mounts to use based on controller
	var securityMountsToUse []interface{}
	if isPtpConfigController {
		// PtpConfig is source of truth for security - use updated (even if empty)
		log.Printf("MergeDaemonSet: PtpConfig reconciling, using %d security mount(s) from updated", len(updatedSecurityMounts))
		securityMountsToUse = updatedSecurityMounts
	} else {
		// PtpOperatorConfig doesn't manage security - preserve from current
		log.Printf("MergeDaemonSet: PtpOperatorConfig reconciling, preserving %d security mount(s) from current", len(currentSecurityMounts))
		securityMountsToUse = currentSecurityMounts
	}

	// Merge mounts for linuxptp-daemon-container
	for i, cont := range updatedContainers {
		contMap, ok := cont.(map[string]interface{})
		if !ok {
			continue
		}
		if name, ok := contMap["name"].(string); ok && name == "linuxptp-daemon-container" {
			mounts, found, err := uns.NestedSlice(contMap, "volumeMounts")
			if err != nil {
				return err
			}
			if !found {
				mounts = []interface{}{}
			}

			// Remove security mounts from base mounts
			mergedMounts := []interface{}{}
			for _, mount := range mounts {
				mountMap, ok := mount.(map[string]interface{})
				if !ok {
					mergedMounts = append(mergedMounts, mount)
					continue
				}
				if mountName, ok := mountMap["name"].(string); ok {
					// Skip security mounts - we'll add from our chosen set
					if len(mountName) >= 14 && mountName[len(mountName)-14:] == "-ptpconfig-sec" {
						continue
					}
				}
				mergedMounts = append(mergedMounts, mount)
			}

			// Add security mounts
			mergedMounts = append(mergedMounts, securityMountsToUse...)
			contMap["volumeMounts"] = mergedMounts
			updatedContainers[i] = contMap
			break
		}
	}

	return uns.SetNestedSlice(updated.Object, updatedContainers, "spec", "template", "spec", "containers")
}

// MergeServiceForUpdate ensures the clusterip is never written to
func MergeServiceForUpdate(current, updated *uns.Unstructured) error {
	gvk := updated.GroupVersionKind()
	if gvk.Group == "" && gvk.Kind == "Service" {
		clusterIP, found, err := uns.NestedString(current.Object, "spec", "clusterIP")
		if err != nil {
			return err
		}

		if found {
			return uns.SetNestedField(updated.Object, clusterIP, "spec", "clusterIP")
		}
	}

	return nil
}

// MergeServiceAccountForUpdate copies secrets from current to updated.
// This is intended to preserve the auto-generated token.
// Right now, we just copy current to updated and don't support supplying
// any secrets ourselves.
func MergeServiceAccountForUpdate(current, updated *uns.Unstructured) error {
	gvk := updated.GroupVersionKind()
	if gvk.Group == "" && gvk.Kind == "ServiceAccount" {
		curSecrets, ok, err := uns.NestedSlice(current.Object, "secrets")
		if err != nil {
			return err
		}

		if ok {
			uns.SetNestedField(updated.Object, curSecrets, "secrets")
		}

		curImagePullSecrets, ok, err := uns.NestedSlice(current.Object, "imagePullSecrets")
		if err != nil {
			return err
		}
		if ok {
			uns.SetNestedField(updated.Object, curImagePullSecrets, "imagePullSecrets")
		}
	}
	return nil
}

// mergeAnnotations copies over any annotations from current to updated,
// with updated winning if there's a conflict
func mergeAnnotations(current, updated *uns.Unstructured) {
	updatedAnnotations := updated.GetAnnotations()
	curAnnotations := current.GetAnnotations()

	if curAnnotations == nil {
		curAnnotations = map[string]string{}
	}

	for k, v := range updatedAnnotations {
		curAnnotations[k] = v
	}

	updated.SetAnnotations(curAnnotations)
}

// mergeLabels copies over any labels from current to updated,
// with updated winning if there's a conflict
func mergeLabels(current, updated *uns.Unstructured) {
	updatedLabels := updated.GetLabels()
	curLabels := current.GetLabels()

	if curLabels == nil {
		curLabels = map[string]string{}
	}

	for k, v := range updatedLabels {
		curLabels[k] = v
	}

	updated.SetLabels(curLabels)
}

// IsObjectSupported rejects objects with configurations we don't support.
// This catches ServiceAccounts with secrets, which is valid but we don't
// support reconciling them.
func IsObjectSupported(obj *uns.Unstructured) error {
	gvk := obj.GroupVersionKind()

	// We cannot create ServiceAccounts with secrets because there's currently
	// no need and the merging logic is complex.
	// If you need this, please file an issue.
	if gvk.Group == "" && gvk.Kind == "ServiceAccount" {
		secrets, ok, err := uns.NestedSlice(obj.Object, "secrets")
		if err != nil {
			return err
		}

		if ok && len(secrets) > 0 {
			return errors.Errorf("cannot create ServiceAccount with secrets")
		}
	}

	return nil
}

// SPDX-License-Identifier: Apache-2.0

package vmnetworkadmission

import (
	"context"
	"errors"
	"fmt"
	"time"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/dynamic"
)

const VMNetworkProtectionFinalizer = "infrastructure.cozystack.io/vmnetwork-reference-protection"

// RunProtectionController keeps the reference-protection finalizer on every
// VMNetwork. A deleting VMNetwork remains present until all VMInstance
// references are gone, which closes the admission TOCTOU window: once DELETE
// is accepted the object has deletionTimestamp set, and VMInstance admission
// rejects new references while this controller waits for existing references
// to drain.
func RunProtectionController(ctx context.Context, dynamicClient dynamic.Interface, dependencies DependencyReader, interval time.Duration) error {
	if dynamicClient == nil {
		return fmt.Errorf("VMNetwork protection dynamic client is not configured")
	}
	if dependencies == nil {
		return fmt.Errorf("VMNetwork protection dependency reader is not configured")
	}
	if interval <= 0 {
		interval = 2 * time.Second
	}

	if err := ReconcileProtectionOnce(ctx, dynamicClient, dependencies); err != nil {
		return err
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-ticker.C:
			if err := ReconcileProtectionOnce(ctx, dynamicClient, dependencies); err != nil {
				return err
			}
		}
	}
}

// ReconcileProtectionOnce performs one fail-closed reconciliation pass. Any
// dependency lookup failure keeps the finalizer in place and returns an error.
func ReconcileProtectionOnce(ctx context.Context, dynamicClient dynamic.Interface, dependencies DependencyReader) error {
	list, err := dynamicClient.Resource(vmNetworkGVR).List(ctx, metav1.ListOptions{})
	if err != nil {
		return fmt.Errorf("list VMNetworks for reference protection: %w", err)
	}

	var errs []error
	for i := range list.Items {
		network := &list.Items[i]
		finalizers := network.GetFinalizers()
		hasProtection := containsString(finalizers, VMNetworkProtectionFinalizer)

		if network.GetDeletionTimestamp() == nil {
			if hasProtection {
				continue
			}
			network.SetFinalizers(append(finalizers, VMNetworkProtectionFinalizer))
			if _, err := dynamicClient.Resource(vmNetworkGVR).Namespace(network.GetNamespace()).Update(ctx, network, metav1.UpdateOptions{}); err != nil {
				if !apierrors.IsConflict(err) && !apierrors.IsNotFound(err) {
					errs = append(errs, fmt.Errorf("add reference protection to VMNetwork %s/%s: %w", network.GetNamespace(), network.GetName(), err))
				}
			}
			continue
		}

		if !hasProtection {
			// Legacy/unprotected deletes are blocked by admission. If one reaches
			// this state through an older controller/version, do not invent a new
			// finalizer on an object already being deleted.
			continue
		}

		vms, err := dependencies.ReferencingVMInstances(ctx, network.GetNamespace(), network.GetName())
		if err != nil {
			errs = append(errs, fmt.Errorf("verify references before releasing VMNetwork %s/%s: %w", network.GetNamespace(), network.GetName(), err))
			continue
		}
		if len(vms) > 0 {
			continue
		}

		network.SetFinalizers(removeString(finalizers, VMNetworkProtectionFinalizer))
		if _, err := dynamicClient.Resource(vmNetworkGVR).Namespace(network.GetNamespace()).Update(ctx, network, metav1.UpdateOptions{}); err != nil {
			if !apierrors.IsConflict(err) && !apierrors.IsNotFound(err) {
				errs = append(errs, fmt.Errorf("release reference protection from VMNetwork %s/%s: %w", network.GetNamespace(), network.GetName(), err))
			}
		}
	}
	return errors.Join(errs...)
}

func containsString(values []string, target string) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}

func removeString(values []string, target string) []string {
	out := make([]string, 0, len(values))
	for _, value := range values {
		if value != target {
			out = append(out, value)
		}
	}
	return out
}

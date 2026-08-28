// SPDX-License-Identifier: Apache-2.0

package vmnetworkadmission

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"time"

	admissionv1 "k8s.io/api/admission/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/dynamic"
)

const VMNetworkProtectionFinalizer = "infrastructure.cozystack.io/vmnetwork-reference-protection"

// NewProtectionAdmissionHandler prevents an unprotected VMNetwork from being
// deleted and prevents tenants from stripping the reference-protection
// finalizer. Only the controller service account may release the finalizer,
// only after deletion has started, and only after references are rechecked.
func NewProtectionAdmissionHandler(dependencies DependencyReader, finalizerRemoverUsername string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, "cannot read AdmissionReview", http.StatusBadRequest)
			return
		}
		_ = r.Body.Close()

		var review admissionv1.AdmissionReview
		if err := json.Unmarshal(body, &review); err != nil || review.Request == nil {
			http.Error(w, "invalid AdmissionReview", http.StatusBadRequest)
			return
		}
		req := review.Request
		if req.Resource.Group == appsGroup && req.Resource.Resource == vmNetworkResource {
			switch req.Operation {
			case admissionv1.Delete:
				oldMeta, err := decodeObjectMeta(req.OldObject.Raw)
				if err != nil {
					writeProtectionResponse(w, req.UID, deny(http.StatusBadRequest, metav1.StatusReasonInvalid, "cannot decode VMNetwork metadata for reference protection"))
					return
				}
				if !containsString(oldMeta.Finalizers, VMNetworkProtectionFinalizer) {
					writeProtectionResponse(w, req.UID, deny(http.StatusConflict, metav1.StatusReasonConflict, "VMNetwork is not yet covered by reference-protection finalizer; retry after the protection controller reconciles it"))
					return
				}
			case admissionv1.Update:
				oldMeta, err := decodeObjectMeta(req.OldObject.Raw)
				if err != nil {
					writeProtectionResponse(w, req.UID, deny(http.StatusBadRequest, metav1.StatusReasonInvalid, "cannot decode old VMNetwork metadata for reference protection"))
					return
				}
				newMeta, err := decodeObjectMeta(req.Object.Raw)
				if err != nil {
					writeProtectionResponse(w, req.UID, deny(http.StatusBadRequest, metav1.StatusReasonInvalid, "cannot decode new VMNetwork metadata for reference protection"))
					return
				}
				oldProtected := containsString(oldMeta.Finalizers, VMNetworkProtectionFinalizer)
				newProtected := containsString(newMeta.Finalizers, VMNetworkProtectionFinalizer)
				if oldProtected && !newProtected {
					if oldMeta.DeletionTimestamp == nil {
						writeProtectionResponse(w, req.UID, deny(http.StatusForbidden, metav1.StatusReasonForbidden, "VMNetwork reference-protection finalizer cannot be removed before deletion starts"))
						return
					}
					if finalizerRemoverUsername == "" || req.UserInfo.Username != finalizerRemoverUsername {
						writeProtectionResponse(w, req.UID, deny(http.StatusForbidden, metav1.StatusReasonForbidden, "only the VMNetwork protection controller may release the reference-protection finalizer"))
						return
					}
					if dependencies == nil {
						writeProtectionResponse(w, req.UID, deny(http.StatusInternalServerError, metav1.StatusReasonInternalError, "VMNetwork dependency reader is not configured"))
						return
					}
					vms, err := dependencies.ReferencingVMInstances(r.Context(), req.Namespace, req.Name)
					if err != nil {
						writeProtectionResponse(w, req.UID, deny(http.StatusInternalServerError, metav1.StatusReasonInternalError, fmt.Sprintf("cannot recheck VMNetwork references before finalizer release: %v", err)))
						return
					}
					if len(vms) > 0 {
						writeProtectionResponse(w, req.UID, deny(http.StatusConflict, metav1.StatusReasonConflict, fmt.Sprintf("cannot release VMNetwork reference protection while VMInstance references remain: %v", vms)))
						return
					}
				}
			}
		}

		r.Body = io.NopCloser(bytes.NewReader(body))
		r.ContentLength = int64(len(body))
		next.ServeHTTP(w, r)
	})
}

func decodeObjectMeta(raw []byte) (*metav1.ObjectMeta, error) {
	var object struct {
		Metadata metav1.ObjectMeta `json:"metadata"`
	}
	if err := json.Unmarshal(raw, &object); err != nil {
		return nil, err
	}
	return &object.Metadata, nil
}

func writeProtectionResponse(w http.ResponseWriter, uid types.UID, response *admissionv1.AdmissionResponse) {
	response.UID = uid
	review := admissionv1.AdmissionReview{
		TypeMeta: metav1.TypeMeta{APIVersion: admissionv1.SchemeGroupVersion.String(), Kind: "AdmissionReview"},
		Response: response,
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(&review)
}

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

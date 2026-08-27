// SPDX-License-Identifier: Apache-2.0

package tenantresolver

import (
	"context"
	"errors"
	"fmt"
	"sort"

	authorizationv1 "k8s.io/api/authorization/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apiserver/pkg/authentication/user"
	"k8s.io/client-go/dynamic"
)

var (
	TenantGVR = schema.GroupVersionResource{Group: "apps.cozystack.io", Version: "v1alpha1", Resource: "tenants"}
	ErrTenantNamespaceUnavailable = errors.New("tenant status.namespace is not available")
	ErrAccessReviewerUnavailable  = errors.New("subject access reviewer is not configured")
	ErrTenantHierarchyCycle       = errors.New("tenant hierarchy contains a cycle")
)

type Ref struct {
	ControlNamespace string
	Name             string
}

func (r Ref) validate() error {
	if r.ControlNamespace == "" { return errors.New("tenant control namespace is required") }
	if r.Name == "" { return errors.New("tenant name is required") }
	return nil
}

type ResourceAccessAttributes struct {
	Verb string
	Group string
	Version string
	Resource string
	Subresource string
	Name string
}

type AccessDecision struct {
	Allowed bool
	Reason string
	EvaluationError string
	Tenant Ref
	Namespace string
}

type SubjectAccessReviewClient interface {
	Create(context.Context, *authorizationv1.SubjectAccessReview, metav1.CreateOptions) (*authorizationv1.SubjectAccessReview, error)
}

type Resolver struct { tenants dynamic.Interface; reviewer SubjectAccessReviewClient }

func New(tenants dynamic.Interface, reviewer SubjectAccessReviewClient) *Resolver { return &Resolver{tenants: tenants, reviewer: reviewer} }

func (r *Resolver) ResolveTenant(ctx context.Context, ref Ref) (*unstructured.Unstructured, error) {
	if err := ref.validate(); err != nil { return nil, err }
	if r.tenants == nil { return nil, errors.New("tenant client is not configured") }
	return r.tenants.Resource(TenantGVR).Namespace(ref.ControlNamespace).Get(ctx, ref.Name, metav1.GetOptions{})
}

func (r *Resolver) ResolveTenantNamespace(ctx context.Context, ref Ref) (string, error) {
	tenant, err := r.ResolveTenant(ctx, ref); if err != nil { return "", err }; return namespaceFromTenant(tenant)
}

func (r *Resolver) ResolveParentTenant(ctx context.Context, ref Ref) (*unstructured.Unstructured, error) {
	tenant, err := r.ResolveTenant(ctx, ref); if err != nil { return nil, err }; return r.resolveParentForTenant(ctx, tenant)
}

func (r *Resolver) ListChildTenants(ctx context.Context, ref Ref) ([]unstructured.Unstructured, error) {
	parent, err := r.ResolveTenant(ctx, ref); if err != nil { return nil, err }
	parentNamespace, err := namespaceFromTenant(parent); if err != nil { return nil, err }
	all, err := r.listTenants(ctx); if err != nil { return nil, err }
	children := make([]unstructured.Unstructured, 0)
	for i := range all.Items {
		candidate := &all.Items[i]
		if sameTenant(parent, candidate) { continue }
		if candidate.GetNamespace() == parentNamespace { children = append(children, *candidate.DeepCopy()) }
	}
	sort.Slice(children, func(i, j int) bool {
		if children[i].GetNamespace() == children[j].GetNamespace() { return children[i].GetName() < children[j].GetName() }
		return children[i].GetNamespace() < children[j].GetNamespace()
	})
	return children, nil
}

func (r *Resolver) CheckTenantAccess(ctx context.Context, identity user.Info, ref Ref, verb string) (AccessDecision, error) {
	if verb == "" { return AccessDecision{}, errors.New("verb is required") }
	tenant, err := r.ResolveTenant(ctx, ref); if err != nil { return AccessDecision{}, err }
	decision, err := r.review(ctx, identity, authorizationv1.ResourceAttributes{Verb: verb, Group: TenantGVR.Group, Version: TenantGVR.Version, Resource: TenantGVR.Resource, Namespace: tenant.GetNamespace(), Name: tenant.GetName()})
	if err != nil { return AccessDecision{}, err }
	decision.Tenant = refFromTenant(tenant); decision.Namespace = tenant.GetNamespace(); return decision, nil
}

func (r *Resolver) CheckInheritedResourceAccess(ctx context.Context, identity user.Info, ref Ref, attrs ResourceAccessAttributes) (AccessDecision, error) {
	if attrs.Verb == "" { return AccessDecision{}, errors.New("verb is required") }
	if attrs.Resource == "" { return AccessDecision{}, errors.New("resource is required") }
	current, err := r.ResolveTenant(ctx, ref); if err != nil { return AccessDecision{}, err }
	visited := map[string]struct{}{}; var last AccessDecision
	for current != nil {
		key := tenantKey(current); if _, ok := visited[key]; ok { return AccessDecision{}, ErrTenantHierarchyCycle }; visited[key] = struct{}{}
		workloadNamespace, err := namespaceFromTenant(current); if err != nil { return AccessDecision{}, err }
		decision, err := r.review(ctx, identity, authorizationv1.ResourceAttributes{Verb: attrs.Verb, Group: attrs.Group, Version: attrs.Version, Resource: attrs.Resource, Subresource: attrs.Subresource, Namespace: workloadNamespace, Name: attrs.Name})
		if err != nil { return AccessDecision{}, err }
		decision.Tenant = refFromTenant(current); decision.Namespace = workloadNamespace; last = decision
		if decision.Allowed { return decision, nil }
		current, err = r.resolveParentForTenant(ctx, current); if err != nil { return AccessDecision{}, err }
	}
	return last, nil
}

func (r *Resolver) resolveParentForTenant(ctx context.Context, tenant *unstructured.Unstructured) (*unstructured.Unstructured, error) {
	if tenant == nil { return nil, errors.New("tenant is nil") }
	parentWorkloadNamespace := tenant.GetNamespace(); all, err := r.listTenants(ctx); if err != nil { return nil, err }
	matches := make([]*unstructured.Unstructured, 0, 1)
	for i := range all.Items {
		candidate := &all.Items[i]; if sameTenant(tenant, candidate) { continue }
		candidateNamespace, found, err := unstructured.NestedString(candidate.Object, "status", "namespace")
		if err != nil { return nil, fmt.Errorf("read status.namespace for tenant %s/%s: %w", candidate.GetNamespace(), candidate.GetName(), err) }
		if found && candidateNamespace != "" && candidateNamespace == parentWorkloadNamespace { matches = append(matches, candidate.DeepCopy()) }
	}
	switch len(matches) { case 0: return nil, nil; case 1: return matches[0], nil; default: return nil, fmt.Errorf("ambiguous tenant hierarchy: %d tenants claim workload namespace %q", len(matches), parentWorkloadNamespace) }
}

func (r *Resolver) listTenants(ctx context.Context) (*unstructured.UnstructuredList, error) {
	if r.tenants == nil { return nil, errors.New("tenant client is not configured") }
	return r.tenants.Resource(TenantGVR).Namespace("").List(ctx, metav1.ListOptions{})
}

func namespaceFromTenant(tenant *unstructured.Unstructured) (string, error) {
	if tenant == nil { return "", errors.New("tenant is nil") }
	namespace, found, err := unstructured.NestedString(tenant.Object, "status", "namespace")
	if err != nil { return "", fmt.Errorf("read status.namespace for tenant %s/%s: %w", tenant.GetNamespace(), tenant.GetName(), err) }
	if !found || namespace == "" { return "", fmt.Errorf("%w for tenant %s/%s", ErrTenantNamespaceUnavailable, tenant.GetNamespace(), tenant.GetName()) }
	return namespace, nil
}

func refFromTenant(tenant *unstructured.Unstructured) Ref { return Ref{ControlNamespace: tenant.GetNamespace(), Name: tenant.GetName()} }
func sameTenant(a, b *unstructured.Unstructured) bool { if a == nil || b == nil { return false }; if a.GetUID() != "" && b.GetUID() != "" { return a.GetUID() == b.GetUID() }; return a.GetNamespace() == b.GetNamespace() && a.GetName() == b.GetName() }
func tenantKey(tenant *unstructured.Unstructured) string { if tenant.GetUID() != "" { return string(tenant.GetUID()) }; return tenant.GetNamespace() + "/" + tenant.GetName() }

func (r *Resolver) review(ctx context.Context, identity user.Info, attrs authorizationv1.ResourceAttributes) (AccessDecision, error) {
	if r.reviewer == nil { return AccessDecision{}, ErrAccessReviewerUnavailable }
	if identity == nil { return AccessDecision{}, errors.New("user identity is required") }
	extra := make(map[string]authorizationv1.ExtraValue, len(identity.GetExtra()))
	for key, values := range identity.GetExtra() { extra[key] = append(authorizationv1.ExtraValue(nil), values...) }
	review, err := r.reviewer.Create(ctx, &authorizationv1.SubjectAccessReview{Spec: authorizationv1.SubjectAccessReviewSpec{User: identity.GetName(), Groups: append([]string(nil), identity.GetGroups()...), Extra: extra, ResourceAttributes: &attrs}}, metav1.CreateOptions{})
	if err != nil { return AccessDecision{}, err }
	if review == nil { return AccessDecision{}, errors.New("subject access review returned no response") }
	return AccessDecision{Allowed: review.Status.Allowed, Reason: review.Status.Reason, EvaluationError: review.Status.EvaluationError}, nil
}

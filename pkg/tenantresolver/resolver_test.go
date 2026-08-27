// SPDX-License-Identifier: Apache-2.0

package tenantresolver

import (
	"context"
	"errors"
	"reflect"
	"testing"

	authorizationv1 "k8s.io/api/authorization/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apiserver/pkg/authentication/user"
	dynamicfake "k8s.io/client-go/dynamic/fake"
)

func TestResolveTenantNamespaceUsesStatus(t *testing.T) {
	resolver := newTestResolver(t, nil, tenant("tenant-root", "finance", "opaque-workload-7c1", "finance"))
	ns, err := resolver.ResolveTenantNamespace(context.Background(), Ref{ControlNamespace: "tenant-root", Name: "finance"})
	if err != nil { t.Fatalf("ResolveTenantNamespace() error = %v", err) }
	if ns != "opaque-workload-7c1" { t.Fatalf("ResolveTenantNamespace() = %q, want %q", ns, "opaque-workload-7c1") }
}

func TestResolveTenantNamespaceRequiresAuthoritativeStatus(t *testing.T) {
	resolver := newTestResolver(t, nil, tenant("tenant-root", "finance", "", "finance"))
	_, err := resolver.ResolveTenantNamespace(context.Background(), Ref{ControlNamespace: "tenant-root", Name: "finance"})
	if !errors.Is(err, ErrTenantNamespaceUnavailable) { t.Fatalf("error = %v, want ErrTenantNamespaceUnavailable", err) }
}

func TestHierarchyUsesTenantObjectRelationships(t *testing.T) {
	root := tenant("tenant-root", "root", "workload-root-91", "root")
	team := tenant("workload-root-91", "blue", "workload-blue-42", "blue")
	ops := tenant("workload-root-91", "operations", "workload-ops-11", "ops")
	dev := tenant("workload-blue-42", "dev", "workload-dev-73", "dev")
	resolver := newTestResolver(t, nil, root, team, ops, dev)
	parent, err := resolver.ResolveParentTenant(context.Background(), Ref{ControlNamespace: "workload-blue-42", Name: "dev"})
	if err != nil { t.Fatalf("ResolveParentTenant() error = %v", err) }
	if got := refFromTenant(parent); got != (Ref{ControlNamespace: "workload-root-91", Name: "blue"}) { t.Fatalf("parent = %#v", got) }
	children, err := resolver.ListChildTenants(context.Background(), Ref{ControlNamespace: "tenant-root", Name: "root"})
	if err != nil { t.Fatalf("ListChildTenants() error = %v", err) }
	got := make([]string, 0, len(children)); for i := range children { got = append(got, children[i].GetName()) }
	want := []string{"blue", "operations"}; if !reflect.DeepEqual(got, want) { t.Fatalf("children = %v, want %v", got, want) }
}

func TestResolveParentTenantRejectsAmbiguousAuthority(t *testing.T) {
	resolver := newTestResolver(t, nil,
		tenant("tenant-root", "a", "shared-workload", "a"),
		tenant("tenant-root", "b", "shared-workload", "b"),
		tenant("shared-workload", "child", "child-workload", "child"),
	)
	if _, err := resolver.ResolveParentTenant(context.Background(), Ref{ControlNamespace: "shared-workload", Name: "child"}); err == nil { t.Fatal("want ambiguous hierarchy error") }
}

func TestCheckTenantAccessUsesControlNamespace(t *testing.T) {
	reviewer := &fakeReviewer{allowNamespaces: map[string]bool{"control-blue": true}}
	resolver := newTestResolver(t, reviewer, tenant("control-blue", "dev", "workload-dev-88", "dev"))
	identity := &user.DefaultInfo{Name: "alice", Groups: []string{"developers"}}
	decision, err := resolver.CheckTenantAccess(context.Background(), identity, Ref{ControlNamespace: "control-blue", Name: "dev"}, "get")
	if err != nil || !decision.Allowed { t.Fatalf("decision=%#v err=%v", decision, err) }
	attrs := reviewer.calls[0].Spec.ResourceAttributes
	if attrs.Namespace != "control-blue" || attrs.Resource != "tenants" || attrs.Name != "dev" { t.Fatalf("attributes=%#v", *attrs) }
}

func TestCheckInheritedResourceAccessUsesResolvedNamespaces(t *testing.T) {
	root := tenant("tenant-root", "root", "workload-root", "root")
	team := tenant("workload-root", "team", "workload-team", "team")
	dev := tenant("workload-team", "dev", "workload-dev", "dev")
	reviewer := &fakeReviewer{allowNamespaces: map[string]bool{"workload-root": true}}
	resolver := newTestResolver(t, reviewer, root, team, dev)
	decision, err := resolver.CheckInheritedResourceAccess(context.Background(), &user.DefaultInfo{Name: "alice"}, Ref{ControlNamespace: "workload-team", Name: "dev"}, ResourceAccessAttributes{Verb: "get", Resource: "configmaps", Name: "shared-policy"})
	if err != nil || !decision.Allowed { t.Fatalf("decision=%#v err=%v", decision, err) }
	got := []string{}; for _, call := range reviewer.calls { got = append(got, call.Spec.ResourceAttributes.Namespace) }
	want := []string{"workload-dev", "workload-team", "workload-root"}; if !reflect.DeepEqual(got, want) { t.Fatalf("namespaces=%v want=%v", got, want) }
}

func newTestResolver(t *testing.T, reviewer SubjectAccessReviewClient, tenants ...*unstructured.Unstructured) *Resolver {
	t.Helper(); objects := make([]runtime.Object, 0, len(tenants)); for _, obj := range tenants { objects = append(objects, obj) }
	client := dynamicfake.NewSimpleDynamicClientWithCustomListKinds(runtime.NewScheme(), map[schema.GroupVersionResource]string{TenantGVR: "TenantList"}, objects...)
	return New(client, reviewer)
}

func tenant(controlNamespace, name, workloadNamespace, uid string) *unstructured.Unstructured {
	obj := &unstructured.Unstructured{}; obj.SetAPIVersion("apps.cozystack.io/v1alpha1"); obj.SetKind("Tenant"); obj.SetNamespace(controlNamespace); obj.SetName(name); obj.SetUID(types.UID(uid))
	if workloadNamespace != "" { obj.Object["status"] = map[string]any{"namespace": workloadNamespace} }
	return obj
}

type fakeReviewer struct { calls []*authorizationv1.SubjectAccessReview; allowNamespaces map[string]bool }
func (f *fakeReviewer) Create(_ context.Context, review *authorizationv1.SubjectAccessReview, _ metav1.CreateOptions) (*authorizationv1.SubjectAccessReview, error) {
	f.calls = append(f.calls, review.DeepCopy()); allowed := false; if review.Spec.ResourceAttributes != nil { allowed = f.allowNamespaces[review.Spec.ResourceAttributes.Namespace] }
	return &authorizationv1.SubjectAccessReview{Status: authorizationv1.SubjectAccessReviewStatus{Allowed: allowed, Denied: !allowed, Reason: "test policy"}}, nil
}

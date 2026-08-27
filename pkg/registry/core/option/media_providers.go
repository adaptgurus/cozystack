// SPDX-License-Identifier: Apache-2.0

package option

import (
	"context"
	"sort"
	"strings"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/client-go/dynamic"

	corev1alpha1 "github.com/cozystack/cozystack/pkg/apis/core/v1alpha1"
)

const isoPVCPrefix = "vm-default-isos-"

// isoProvider exposes only the platform ISO Library PVCs. This deliberately
// follows the same public-catalog ownership pattern as imageProvider and avoids
// granting the option API any additional CDI privileges.
func isoProvider(dyn dynamic.Interface) providerFunc {
	return func(ctx context.Context, _ string) ([]corev1alpha1.OptionItem, error) {
		list, err := dyn.Resource(gvrPVCs).Namespace(publicImagesNamespace).List(ctx, listOpts())
		if err != nil {
			return nil, err
		}
		items := make([]corev1alpha1.OptionItem, 0, len(list.Items))
		for i := range list.Items {
			name := list.Items[i].GetName()
			if !strings.HasPrefix(name, isoPVCPrefix) {
				continue
			}
			value := strings.TrimPrefix(name, isoPVCPrefix)
			items = append(items, corev1alpha1.OptionItem{Value: value, Label: value})
		}
		sort.Slice(items, func(i, j int) bool { return items[i].Value < items[j].Value })
		return items, nil
	}
}

// opticalDiskProvider lists only tenant-local VMDisk objects that represent
// optical media. Platform ISO clones count as optical even if their explicit
// spec.optical field is false because source.iso is intrinsically optical.
func opticalDiskProvider(dyn dynamic.Interface) providerFunc {
	return func(ctx context.Context, namespace string) ([]corev1alpha1.OptionItem, error) {
		if namespace == "" {
			return nil, nil
		}
		list, err := dyn.Resource(gvrVMDisks).Namespace(namespace).List(ctx, listOpts())
		if err != nil {
			return nil, err
		}
		items := make([]corev1alpha1.OptionItem, 0, len(list.Items))
		for i := range list.Items {
			obj := &list.Items[i]
			optical, _, _ := unstructured.NestedBool(obj.Object, "spec", "optical")
			_, platformISO, _ := unstructured.NestedMap(obj.Object, "spec", "source", "iso")
			if !optical && !platformISO {
				continue
			}
			name := obj.GetName()
			label, _, _ := unstructured.NestedString(obj.Object, "spec", "displayName")
			if label == "" {
				label = name
			}
			category, _, _ := unstructured.NestedString(obj.Object, "spec", "mediaCategory")
			description, _, _ := unstructured.NestedString(obj.Object, "spec", "description")
			var details []string
			if category != "" {
				details = append(details, category)
			}
			if description != "" {
				details = append(details, description)
			}
			items = append(items, corev1alpha1.OptionItem{Value: name, Label: label, Description: strings.Join(details, " · ")})
		}
		sort.Slice(items, func(i, j int) bool { return items[i].Value < items[j].Value })
		return items, nil
	}
}

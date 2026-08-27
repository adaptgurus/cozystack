// SPDX-License-Identifier: Apache-2.0

package option

import (
	"context"
	"fmt"
	"sort"
	"strings"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/dynamic"

	corev1alpha1 "github.com/cozystack/cozystack/pkg/apis/core/v1alpha1"
)

const isoDataVolumePrefix = "vm-default-isos-"

var gvrDataVolumes = schema.GroupVersionResource{Group: "cdi.kubevirt.io", Version: "v1beta1", Resource: "datavolumes"}

// isoProvider exposes only the platform ISO Library. It intentionally lists
// DataVolumes rather than arbitrary PVCs so catalog metadata and readiness can
// be surfaced without mixing ISO media with golden VM disk images.
func isoProvider(dyn dynamic.Interface) providerFunc {
	return func(ctx context.Context, _ string) ([]corev1alpha1.OptionItem, error) {
		list, err := dyn.Resource(gvrDataVolumes).Namespace(publicImagesNamespace).List(ctx, listOpts())
		if err != nil {
			return nil, err
		}
		items := make([]corev1alpha1.OptionItem, 0, len(list.Items))
		for i := range list.Items {
			dv := &list.Items[i]
			if !strings.HasPrefix(dv.GetName(), isoDataVolumePrefix) {
				continue
			}
			annotations := dv.GetAnnotations()
			if annotations["vm-disk.cozystack.io/optical"] != "true" {
				continue
			}
			value := strings.TrimPrefix(dv.GetName(), isoDataVolumePrefix)
			label := annotations["vm-default-isos.cozystack.io/name"]
			if label == "" {
				label = value
			}
			category := annotations["vm-default-isos.cozystack.io/category"]
			osName := annotations["vm-default-isos.cozystack.io/os-name"]
			osVersion := annotations["vm-default-isos.cozystack.io/os-version"]
			description := annotations["vm-default-isos.cozystack.io/description"]
			var details []string
			if category != "" {
				details = append(details, category)
			}
			if osName != "" {
				if osVersion != "" {
					details = append(details, fmt.Sprintf("%s %s", osName, osVersion))
				} else {
					details = append(details, osName)
				}
			}
			if description != "" {
				details = append(details, description)
			}
			items = append(items, corev1alpha1.OptionItem{Value: value, Label: label, Description: strings.Join(details, " · ")})
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

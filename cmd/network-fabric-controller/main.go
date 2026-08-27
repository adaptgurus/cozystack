// SPDX-License-Identifier: Apache-2.0

package main

import (
	"flag"
	"fmt"
	"net/http"
	"os"
	"time"

	"github.com/cozystack/cozystack/pkg/networkfabric"
	"github.com/cozystack/cozystack/pkg/networkfabriccontroller"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/healthz"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"
)

func main() {
	var metricsAddr, healthAddr, talosconfig string
	var requeue, tryTimeout time.Duration
	var allowControlPlaneNetworking bool
	flag.StringVar(&metricsAddr, "metrics-bind-address", ":8080", "metrics bind address")
	flag.StringVar(&healthAddr, "health-probe-bind-address", ":8081", "health probe bind address")
	flag.StringVar(&talosconfig, "talosconfig", "/var/run/secrets/talos.dev/config", "path to Talos client configuration")
	flag.DurationVar(&requeue, "health-requeue", 2*time.Minute, "periodic NetworkFabric health recheck")
	flag.DurationVar(&tryTimeout, "talos-try-timeout", 2*time.Minute, "Talos try-mode automatic rollback timeout")
	flag.BoolVar(&allowControlPlaneNetworking, "allow-control-plane-networking", false, "allow NetworkFabric Talos mutation on Ready control-plane nodes explicitly selected by a fabric (disabled by default)")
	flag.Parse()

	scheme := runtime.NewScheme()
	utilruntime.Must(clientgoscheme.AddToScheme(scheme))

	mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), ctrl.Options{
		Scheme:                 scheme,
		Metrics:                metricsserver.Options{BindAddress: metricsAddr},
		HealthProbeBindAddress: healthAddr,
		LeaderElection:         true,
		LeaderElectionID:       "network-fabric-controller.infrastructure.cozystack.io",
	})
	if err != nil {
		panic(err)
	}

	baseReconciler := &networkfabriccontroller.Reconciler{
		Client:       mgr.GetClient(),
		RequeueAfter: requeue,
		AdapterFactory: func(node *corev1.Node) (networkfabric.TalosAdapter, error) {
			if err := validateKubernetesNodeForTalosMutation(node, allowControlPlaneNetworking); err != nil {
				return nil, err
			}
			endpoint, err := networkfabriccontroller.TalosEndpoint(node)
			if err != nil {
				return nil, err
			}
			return &networkfabric.TalosAPIAdapter{Talosconfig: talosconfig, Endpoint: endpoint, TryTimeout: tryTimeout}, nil
		},
	}
	reconciler := networkfabriccontroller.NewInstrumentedReconciler(baseReconciler)

	fabric := &unstructured.Unstructured{}
	fabric.SetGroupVersionKind(networkfabriccontroller.NetworkFabricGVK)
	if err := ctrl.NewControllerManagedBy(mgr).Named("networkfabric-talos").For(fabric).Complete(reconciler); err != nil {
		panic(err)
	}

	capabilityReconciler := &networkfabriccontroller.CapabilityReconciler{
		Client:       mgr.GetClient(),
		RequeueAfter: requeue,
	}
	capabilityFabric := &unstructured.Unstructured{}
	capabilityFabric.SetGroupVersionKind(networkfabriccontroller.NetworkFabricGVK)
	if err := ctrl.NewControllerManagedBy(mgr).Named("networkfabric-capabilities").For(capabilityFabric).Complete(capabilityReconciler); err != nil {
		panic(err)
	}

	if err := mgr.AddHealthzCheck("healthz", healthz.Ping); err != nil {
		panic(err)
	}
	if err := mgr.AddReadyzCheck("readyz", healthz.Ping); err != nil {
		panic(err)
	}
	if err := mgr.AddReadyzCheck("talosconfig", talosConfigReadyz(talosconfig)); err != nil {
		panic(err)
	}
	if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
		ctrl.Log.Error(err, "controller manager stopped")
		os.Exit(1)
	}
}

func validateKubernetesNodeForTalosMutation(node *corev1.Node, allowControlPlane bool) error {
	if node == nil {
		return fmt.Errorf("Kubernetes Node is required before Talos mutation")
	}
	ready := false
	for _, condition := range node.Status.Conditions {
		if condition.Type == corev1.NodeReady {
			ready = condition.Status == corev1.ConditionTrue
			break
		}
	}
	if !ready {
		return fmt.Errorf("Kubernetes Node %q is not Ready; refusing Talos network mutation", node.Name)
	}
	_, controlPlane := node.Labels["node-role.kubernetes.io/control-plane"]
	_, legacyMaster := node.Labels["node-role.kubernetes.io/master"]
	if (controlPlane || legacyMaster) && !allowControlPlane {
		return fmt.Errorf("Kubernetes Node %q is a control-plane node; physical network mutation is disabled by default", node.Name)
	}
	return nil
}

func talosConfigReadyz(path string) healthz.Checker {
	return func(_ *http.Request) error {
		info, err := os.Stat(path)
		if err != nil {
			return fmt.Errorf("Talos client configuration is unavailable: %w", err)
		}
		if !info.Mode().IsRegular() {
			return fmt.Errorf("Talos client configuration %q is not a regular file", path)
		}
		if info.Size() == 0 {
			return fmt.Errorf("Talos client configuration %q is empty", path)
		}
		f, err := os.Open(path)
		if err != nil {
			return fmt.Errorf("Talos client configuration %q is not readable: %w", path, err)
		}
		return f.Close()
	}
}

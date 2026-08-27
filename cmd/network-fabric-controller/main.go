// SPDX-License-Identifier: Apache-2.0

package main

import (
	"flag"
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
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/healthz"
)

func main() {
	var metricsAddr, healthAddr, talosconfig, talosctl string
	var requeue, tryTimeout time.Duration
	flag.StringVar(&metricsAddr, "metrics-bind-address", ":8080", "metrics bind address")
	flag.StringVar(&healthAddr, "health-probe-bind-address", ":8081", "health probe bind address")
	flag.StringVar(&talosconfig, "talosconfig", "/var/run/secrets/talos.dev/config", "path to Talos client configuration")
	flag.StringVar(&talosctl, "talosctl", "/usr/local/bin/talosctl", "path to talosctl")
	flag.DurationVar(&requeue, "health-requeue", 2*time.Minute, "periodic NetworkFabric health recheck")
	flag.DurationVar(&tryTimeout, "talos-try-timeout", 2*time.Minute, "Talos try-mode automatic rollback timeout")
	flag.Parse()

	scheme := runtime.NewScheme()
	utilruntime.Must(clientgoscheme.AddToScheme(scheme))

	mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), ctrl.Options{
		Scheme:                 scheme,
		Metrics:                ctrl.MetricsServerOptions{BindAddress: metricsAddr},
		HealthProbeBindAddress: healthAddr,
		LeaderElection:         true,
		LeaderElectionID:       "network-fabric-controller.infrastructure.cozystack.io",
	})
	if err != nil {
		panic(err)
	}

	reconciler := &networkfabriccontroller.Reconciler{
		Client:       mgr.GetClient(),
		RequeueAfter: requeue,
		AdapterFactory: func(node *corev1.Node) (networkfabric.TalosAdapter, error) {
			endpoint, err := networkfabriccontroller.TalosEndpoint(node)
			if err != nil { return nil, err }
			return &networkfabric.TalosctlAdapter{Binary: talosctl, Talosconfig: talosconfig, Endpoint: endpoint, TryTimeout: tryTimeout}, nil
		},
	}

	fabric := &unstructured.Unstructured{}
	fabric.SetGroupVersionKind(networkfabriccontroller.NetworkFabricGVK)
	if err := ctrl.NewControllerManagedBy(mgr).For(fabric).Complete(reconciler); err != nil {
		panic(err)
	}
	if err := mgr.AddHealthzCheck("healthz", healthz.Ping); err != nil { panic(err) }
	if err := mgr.AddReadyzCheck("readyz", healthz.Ping); err != nil { panic(err) }
	if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
		ctrl.Log.Error(err, "controller manager stopped")
		os.Exit(1)
	}
}

var _ client.Client

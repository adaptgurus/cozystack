// SPDX-License-Identifier: Apache-2.0

package main

import (
	"flag"
	"fmt"
	"net/http"
	"os"
	"time"

	"github.com/cozystack/cozystack/pkg/vmtemplate"
	"github.com/cozystack/cozystack/pkg/vmtemplatecontroller"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	"k8s.io/client-go/dynamic"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/healthz"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"
)

func main() {
	var metricsAddr, healthAddr string
	var requeue time.Duration
	flag.StringVar(&metricsAddr, "metrics-bind-address", ":8080", "metrics bind address")
	flag.StringVar(&healthAddr, "health-probe-bind-address", ":8081", "health probe bind address")
	flag.DurationVar(&requeue, "requeue", 5*time.Second, "template transaction reconciliation interval while work is pending")
	flag.Parse()

	config := ctrl.GetConfigOrDie()
	dyn, err := dynamic.NewForConfig(config)
	if err != nil {
		panic(fmt.Errorf("create dynamic Kubernetes client: %w", err))
	}
	backend := &vmtemplate.KubeVirtTemplateBackend{Client: dyn}

	scheme := runtime.NewScheme()
	utilruntime.Must(clientgoscheme.AddToScheme(scheme))
	mgr, err := ctrl.NewManager(config, ctrl.Options{
		Scheme:                 scheme,
		Metrics:                metricsserver.Options{BindAddress: metricsAddr},
		HealthProbeBindAddress: healthAddr,
		LeaderElection:         true,
		LeaderElectionID:       "vm-template-controller.virtualization.cozystack.io",
	})
	if err != nil {
		panic(err)
	}

	reconciler := &vmtemplatecontroller.Reconciler{Client: mgr.GetClient(), Backend: backend, RequeueAfter: requeue}
	op := &unstructured.Unstructured{}
	op.SetGroupVersionKind(vmtemplatecontroller.OperationGVK)
	if err := ctrl.NewControllerManagedBy(mgr).Named("vm-template-operation").For(op).Complete(reconciler); err != nil {
		panic(err)
	}

	if err := mgr.AddHealthzCheck("healthz", healthz.Ping); err != nil {
		panic(err)
	}
	if err := mgr.AddReadyzCheck("readyz", healthz.Ping); err != nil {
		panic(err)
	}
	if err := mgr.AddReadyzCheck("kubevirt-template-capability", templateCapabilityReadyz(backend)); err != nil {
		panic(err)
	}
	if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
		ctrl.Log.Error(err, "controller manager stopped")
		os.Exit(1)
	}
}

func templateCapabilityReadyz(backend vmtemplate.Backend) healthz.Checker {
	return func(req *http.Request) error {
		caps, err := backend.DiscoverCapabilities(req.Context())
		if err != nil {
			return err
		}
		if !caps.NativeTemplatesReady() {
			return fmt.Errorf("KubeVirt native template capability is incomplete: Snapshot=%t Template=%t virtTemplateDeployment=%t", caps.SnapshotGate, caps.TemplateGate, caps.TemplateDeployment)
		}
		return nil
	}
}

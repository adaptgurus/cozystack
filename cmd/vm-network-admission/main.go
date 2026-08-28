// SPDX-License-Identifier: Apache-2.0

package main

import (
	"context"
	"crypto/tls"
	"flag"
	"log"
	"net/http"
	"os/signal"
	"syscall"
	"time"

	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/rest"

	"github.com/cozystack/cozystack/pkg/vmnetworkadmission"
)

func main() {
	addr := flag.String("listen-address", ":9443", "HTTPS listen address")
	certFile := flag.String("tls-cert-file", "/tls/tls.crt", "serving certificate")
	keyFile := flag.String("tls-private-key-file", "/tls/tls.key", "serving private key")
	flag.Parse()

	cfg, err := rest.InClusterConfig()
	if err != nil {
		log.Fatalf("build in-cluster config: %v", err)
	}
	dyn, err := dynamic.NewForConfig(cfg)
	if err != nil {
		log.Fatalf("build Kubernetes dynamic client: %v", err)
	}

	mux := http.NewServeMux()
	validator := vmnetworkadmission.NewHandler(
		vmnetworkadmission.NewDynamicDependencyReader(dyn),
		vmnetworkadmission.NewDynamicFabricReader(dyn),
	).WithNetworkReferenceReader(vmnetworkadmission.NewDynamicNetworkReferenceReader(dyn))
	authorized := vmnetworkadmission.NewTenantAuthorizationHandler(dyn, validator)
	mux.Handle("/validate-vmnetwork", vmnetworkadmission.NewStrictHandler(authorized, vmnetworkadmission.DefaultMaxAdmissionBodyBytes))
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok\n"))
	})

	server := &http.Server{
		Addr:              *addr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    16 << 10,
		TLSConfig: &tls.Config{
			MinVersion: tls.VersionTLS12,
		},
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := server.Shutdown(shutdownCtx); err != nil {
			log.Printf("graceful shutdown: %v", err)
		}
	}()

	log.Printf("VMNetwork/VMInstance network validating admission listening on %s", *addr)
	if err := server.ListenAndServeTLS(*certFile, *keyFile); err != nil && err != http.ErrServerClosed {
		log.Fatalf("serve admission webhook: %v", err)
	}
}

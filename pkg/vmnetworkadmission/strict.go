// SPDX-License-Identifier: Apache-2.0

package vmnetworkadmission

import (
	"bytes"
	"encoding/json"
	"io"
	"mime"
	"net/http"

	admissionv1 "k8s.io/api/admission/v1"
)

const DefaultMaxAdmissionBodyBytes int64 = 1 << 20 // 1 MiB

// NewStrictHandler wraps the VMNetwork admission handler with protocol and
// request-shape validation. Any malformed request is rejected at HTTP level so
// Kubernetes failurePolicy=Fail cannot accidentally turn parser ambiguity into
// an allowed mutation.
func NewStrictHandler(next http.Handler, maxBodyBytes int64) http.Handler {
	if maxBodyBytes <= 0 {
		maxBodyBytes = DefaultMaxAdmissionBodyBytes
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "admission endpoint requires POST", http.StatusMethodNotAllowed)
			return
		}

		mediaType, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
		if err != nil || mediaType != "application/json" {
			http.Error(w, "admission endpoint requires application/json", http.StatusUnsupportedMediaType)
			return
		}

		r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)
		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, "admission request body is invalid or too large", http.StatusRequestEntityTooLarge)
			return
		}
		_ = r.Body.Close()

		var review admissionv1.AdmissionReview
		if err := json.Unmarshal(body, &review); err != nil || review.Request == nil {
			http.Error(w, "invalid AdmissionReview", http.StatusBadRequest)
			return
		}
		req := review.Request
		if req.UID == "" || req.Namespace == "" || req.Name == "" {
			http.Error(w, "AdmissionReview request UID, namespace, and name are required", http.StatusBadRequest)
			return
		}
		if req.Resource.Group != appsGroup || req.Resource.Resource != vmNetworkResource {
			http.Error(w, "unexpected admission resource", http.StatusBadRequest)
			return
		}
		switch req.Operation {
		case admissionv1.Create:
			if len(req.Object.Raw) == 0 {
				http.Error(w, "CREATE admission requires object", http.StatusBadRequest)
				return
			}
		case admissionv1.Update:
			if len(req.Object.Raw) == 0 || len(req.OldObject.Raw) == 0 {
				http.Error(w, "UPDATE admission requires object and oldObject", http.StatusBadRequest)
				return
			}
		case admissionv1.Delete:
			// Request metadata is authoritative for dependency lookup. oldObject may
			// be omitted depending on admission configuration and is not required.
		default:
			http.Error(w, "unsupported admission operation", http.StatusBadRequest)
			return
		}

		r.Body = io.NopCloser(bytes.NewReader(body))
		r.ContentLength = int64(len(body))
		next.ServeHTTP(w, r)
	})
}

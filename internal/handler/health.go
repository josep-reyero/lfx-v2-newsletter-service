// Copyright The Linux Foundation and each contributor to LFX.
// SPDX-License-Identifier: MIT

package handler

import (
	"context"
	"log/slog"
	"net/http"
	"time"
)

// Livez returns 200 if the process is alive. No external dependencies.
func (h *Handler) Livez(w http.ResponseWriter, r *http.Request) {
	_ = r
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok"))
}

// Readyz returns 200 if the database is reachable, 503 otherwise.
func (h *Handler) Readyz(w http.ResponseWriter, r *http.Request) {
	if h.db == nil {
		w.WriteHeader(http.StatusServiceUnavailable)
		_, _ = w.Write([]byte("no db"))
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	if err := h.db.PingContext(ctx); err != nil {
		slog.WarnContext(r.Context(), "readyz: db ping failed", "error", err.Error())
		w.WriteHeader(http.StatusServiceUnavailable)
		_, _ = w.Write([]byte("db unavailable"))
		return
	}
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok"))
}

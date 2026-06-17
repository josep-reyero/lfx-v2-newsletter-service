// Copyright The Linux Foundation and each contributor to LFX.
// SPDX-License-Identifier: MIT

package handler

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

// Statusz must not assume a database is present: with a nil DB it reports 503
// (like Readyz), rather than panicking or falsely claiming readiness.
func TestStatuszNilDBReturns503(t *testing.T) {
	h := &Handler{}
	rec := httptest.NewRecorder()
	h.Statusz(rec, httptest.NewRequest(http.MethodGet, "/statusz", nil))

	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("nil DB: got status %d, want %d", rec.Code, http.StatusServiceUnavailable)
	}
}

// The /statusz route must be wired into Routes(), so the endpoint is reachable
// (a 404 would mean the handler exists but was never registered).
func TestStatuszRouteRegistered(t *testing.T) {
	h := &Handler{}
	rec := httptest.NewRecorder()
	h.Routes().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/statusz", nil))

	if rec.Code == http.StatusNotFound {
		t.Fatal("GET /statusz is not registered in Routes() (got 404)")
	}
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("GET /statusz with nil DB: got status %d, want %d", rec.Code, http.StatusServiceUnavailable)
	}
}

// Copyright The Linux Foundation and each contributor to LFX.
// SPDX-License-Identifier: MIT

// Package handler exposes the HTTP API for the newsletter service. It
// translates between transport (HTTP/JSON) and the service-layer business
// logic, and is the only layer that knows about HTTP status codes.
package handler

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"

	"github.com/linuxfoundation/lfx-v2-newsletter-service/internal/domain"
	"github.com/linuxfoundation/lfx-v2-newsletter-service/internal/domain/port"
	"github.com/linuxfoundation/lfx-v2-newsletter-service/internal/service"
	pkgerrors "github.com/linuxfoundation/lfx-v2-newsletter-service/pkg/errors"
)

// Handler is the HTTP handler aggregate that owns the service-layer dependencies
// and exposes registered routes via Routes().
type Handler struct {
	newsletter      *service.NewsletterService
	send            *service.SendOrchestrator
	analytics       *service.AnalyticsService
	unsub           *service.UnsubscribeService
	project         port.ProjectMetadataClient
	db              *sql.DB
	auth            *AuthValidator
	requireUserAuth bool
}

// Config wires a Handler.
type Config struct {
	Newsletter      *service.NewsletterService
	Send            *service.SendOrchestrator
	Analytics       *service.AnalyticsService
	Unsubscribe     *service.UnsubscribeService
	Project         port.ProjectMetadataClient
	DB              *sql.DB
	Auth            *AuthValidator
	RequireUserAuth bool
}

// New wires a Handler with the given dependencies.
func New(cfg Config) *Handler {
	return &Handler{
		newsletter:      cfg.Newsletter,
		send:            cfg.Send,
		analytics:       cfg.Analytics,
		unsub:           cfg.Unsubscribe,
		project:         cfg.Project,
		db:              cfg.DB,
		auth:            cfg.Auth,
		requireUserAuth: cfg.RequireUserAuth,
	}
}

// projectDisplayName resolves a human-readable project name for use in
// recipient-facing pages, falling back to a generic label when the lookup
// fails so the page always renders.
func (h *Handler) projectDisplayName(ctx context.Context, projectUID string) string {
	if h.project == nil {
		return "this project's"
	}
	name, err := h.project.Name(ctx, projectUID)
	if err != nil || name == "" {
		return "this project's"
	}
	return name
}

// Routes returns a fully-wired http.Handler with all newsletter routes registered.
//
// All authenticated paths are project-scoped (`/projects/{project_uid}/...`)
// so the Heimdall ruleset can gate by `project:{project_uid}` extracted from
// `Request.URL.Captures.project_uid`. Drafts and sent newsletters share one
// resource; status is a field on the row, not a sub-path.
//
// The open-pixel endpoint also carries `project_uid` for path consistency,
// but Heimdall lets it through anonymously — recipients clicking the tracker
// have no session.
func (h *Handler) Routes() http.Handler {
	mux := http.NewServeMux()

	// Health endpoints — no auth.
	mux.HandleFunc("GET /livez", h.Livez)
	mux.HandleFunc("GET /readyz", h.Readyz)
	mux.HandleFunc("GET /statusz", h.Statusz)

	// Newsletter CRUD — JWT auth via withAuth().
	mux.Handle("POST /projects/{project_uid}/newsletters", h.withAuth(http.HandlerFunc(h.CreateNewsletter)))
	mux.Handle("GET /projects/{project_uid}/newsletters", h.withAuth(http.HandlerFunc(h.ListNewsletters)))
	mux.Handle("GET /projects/{project_uid}/newsletters/{newsletter_uid}", h.withAuth(http.HandlerFunc(h.GetNewsletter)))
	mux.Handle("PUT /projects/{project_uid}/newsletters/{newsletter_uid}", h.withAuth(http.HandlerFunc(h.UpdateNewsletter)))
	mux.Handle("DELETE /projects/{project_uid}/newsletters/{newsletter_uid}", h.withAuth(http.HandlerFunc(h.DeleteNewsletter)))
	mux.Handle("POST /projects/{project_uid}/newsletters/{newsletter_uid}/send", h.withAuth(http.HandlerFunc(h.SendNewsletter)))

	// Recipient resolution + test send — JWT auth.
	mux.Handle("POST /projects/{project_uid}/newsletters/recipient-count", h.withAuth(http.HandlerFunc(h.RecipientCount)))
	mux.Handle("POST /projects/{project_uid}/newsletters/recipients", h.withAuth(http.HandlerFunc(h.Recipients)))
	mux.Handle("POST /projects/{project_uid}/newsletters/test-send", h.withAuth(http.HandlerFunc(h.TestSend)))

	// Per-newsletter analytics — JWT auth.
	mux.Handle("GET /projects/{project_uid}/newsletters/{newsletter_uid}/analytics", h.withAuth(http.HandlerFunc(h.GetAnalytics)))

	// Open tracking pixel — intentionally unauthenticated; requested by the
	// recipient's email client which has no session. Identity comes from the
	// hash in the query string.
	mux.HandleFunc("GET /projects/{project_uid}/newsletter-opens/{newsletter_uid}", h.OpenPixel)

	// One-click unsubscribe — intentionally unauthenticated; requested by a
	// recipient clicking the footer link. Authorization comes from the
	// HMAC-signed token in the query string.
	mux.HandleFunc("GET /newsletters/unsubscribe", h.Unsubscribe)

	// Outermost middleware first: request ID so it appears on every log line,
	// then request log so it captures status + duration.
	return withRequestID(h.withRequestLog(mux))
}

// writeJSON serializes v as JSON and writes the given status. Errors are logged
// but not propagated; once headers are written there is no recovery.
func writeJSON(ctx context.Context, w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	if v == nil {
		return
	}
	if err := json.NewEncoder(w).Encode(v); err != nil {
		slog.ErrorContext(ctx, "failed to encode response", "error", err)
	}
}

// errorPayload is the JSON shape returned for error responses.
type errorPayload struct {
	Error   string `json:"error"`
	Message string `json:"message,omitempty"`
}

// writeError maps a domain error to an HTTP status code + JSON body.
//
// For 5xx responses we deliberately do not echo err.Error() to the client —
// internal errors (DB failures, upstream responses) can carry infrastructure
// details. The full error is still logged server-side at the warn level.
func writeError(ctx context.Context, w http.ResponseWriter, err error) {
	status, code := classifyError(err)
	slog.WarnContext(ctx, "request failed",
		"status", status,
		"code", code,
		"error", err.Error(),
	)
	message := err.Error()
	if status >= http.StatusInternalServerError {
		message = "internal server error"
	}
	writeJSON(ctx, w, status, errorPayload{
		Error:   code,
		Message: message,
	})
}

// classifyError maps an error to an HTTP status code and short error code.
//
// Two error families are recognized:
//
//   - domain sentinel errors (`domain.Err*`), matched with `errors.Is`. These
//     are returned by the repository and service layers for well-known
//     business-logic outcomes.
//   - typed `pkgerrors.*` wrappers (`Validation`, `NotFound`, `Conflict`,
//     `ServiceUnavailable`), matched with `errors.As`. These are returned by
//     the NATS upstream clients (committee, project, email-dispatcher) since
//     they don't have a domain sentinel to wrap.
//
// Domain matches take precedence over the typed wrappers. Anything else falls
// through to 500.
func classifyError(err error) (int, string) {
	if status, code, ok := classifyAuthError(err); ok {
		return status, code
	}
	var (
		svcUnavailable pkgerrors.ServiceUnavailable
		notFound       pkgerrors.NotFound
		validation     pkgerrors.Validation
		conflict       pkgerrors.Conflict
	)
	switch {
	case errors.Is(err, domain.ErrNotFound):
		return http.StatusNotFound, "not_found"
	case errors.Is(err, domain.ErrVersionMismatch):
		return http.StatusPreconditionFailed, "version_mismatch"
	case errors.Is(err, domain.ErrAlreadySent):
		return http.StatusConflict, "already_sent"
	case errors.Is(err, domain.ErrInvalidRequest):
		return http.StatusBadRequest, "invalid_request"
	case errors.As(err, &svcUnavailable):
		return http.StatusServiceUnavailable, "service_unavailable"
	case errors.As(err, &notFound):
		return http.StatusNotFound, "not_found"
	case errors.As(err, &validation):
		return http.StatusBadRequest, "invalid_request"
	case errors.As(err, &conflict):
		return http.StatusConflict, "conflict"
	default:
		return http.StatusInternalServerError, "internal_error"
	}
}

// maxRequestBodyBytes caps inbound JSON bodies. Newsletter body_html is the
// largest legitimate field (capped at 100 KiB in the service layer); 1 MiB
// gives generous headroom while bounding the per-request allocation when a
// client streams a hostile payload.
const maxRequestBodyBytes = 1 << 20

// decodeJSON decodes the request body into dst, returning a domain.ErrInvalidRequest
// if the body is missing, malformed, or exceeds maxRequestBodyBytes.
func decodeJSON(r *http.Request, dst any) error {
	if r.Body == nil {
		return domain.ErrInvalidRequest
	}
	defer func() { _ = r.Body.Close() }()
	r.Body = http.MaxBytesReader(nil, r.Body, maxRequestBodyBytes)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		return errors.Join(domain.ErrInvalidRequest, err)
	}
	return nil
}

package dynamicrouting

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	policy "github.com/wso2/api-platform/sdk/core/policy/v1alpha2"
)

// newReqCtx builds a RequestHeaderContext as jwt-auth would hand it to this
// policy: Authenticated, with org_id in Properties (the verified claim),
// and the caller's own bearer token on the incoming Authorization header.
func newReqCtx(orgID, callerToken string) *policy.RequestHeaderContext {
	headers := map[string][]string{}
	if callerToken != "" {
		headers["authorization"] = []string{"Bearer " + callerToken}
	}
	var authContext *policy.AuthContext
	if orgID != "" {
		authContext = &policy.AuthContext{
			Authenticated: true,
			Properties:    map[string]string{defaultOrgIDClaim: orgID},
		}
	}
	return &policy.RequestHeaderContext{
		SharedContext: &policy.SharedContext{AuthContext: authContext},
		Headers:       policy.NewHeaders(headers),
	}
}

func TestOnRequestHeaders_KnownOrg_ExchangesTokenAndRoutes(t *testing.T) {
	exchangeServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer caller-token-123" {
			t.Errorf("expected caller token forwarded, got %q", r.Header.Get("Authorization"))
		}
		json.NewEncoder(w).Encode(map[string]string{"access_token": "backend-token-abc"})
	}))
	defer exchangeServer.Close()

	p, err := GetPolicy(policy.PolicyMetadata{}, map[string]interface{}{"exchangeServiceUrl": exchangeServer.URL})
	if err != nil {
		t.Fatalf("GetPolicy failed: %v", err)
	}

	action := p.(policy.RequestHeaderPolicy).OnRequestHeaders(context.Background(), newReqCtx("Railco", "caller-token-123"), nil)

	mods, ok := action.(policy.UpstreamRequestHeaderModifications)
	if !ok {
		t.Fatalf("expected UpstreamRequestHeaderModifications, got %T", action)
	}
	if mods.UpstreamName == nil || *mods.UpstreamName != "Railco" {
		t.Fatalf("expected UpstreamName=%q, got %v", "Railco", mods.UpstreamName)
	}
	if got := mods.HeadersToSet["X-Backend-Token"]; got != "Bearer backend-token-abc" {
		t.Fatalf("expected exchanged X-Backend-Token header, got %q", got)
	}
	if _, set := mods.HeadersToSet["Authorization"]; set {
		t.Fatalf("expected Authorization to not be re-set, but it was")
	}
	found := false
	for _, h := range mods.HeadersToRemove {
		if h == "authorization" {
			found = true
		}
	}
	if !found {
		t.Fatalf("expected the caller's original Authorization header to be removed, got HeadersToRemove=%v", mods.HeadersToRemove)
	}
}

func TestOnRequestHeaders_NoAuthContext_Returns503(t *testing.T) {
	p, err := GetPolicy(policy.PolicyMetadata{}, nil)
	if err != nil {
		t.Fatalf("GetPolicy failed: %v", err)
	}

	action := p.(policy.RequestHeaderPolicy).OnRequestHeaders(context.Background(), newReqCtx("", "caller-token-123"), nil)

	resp, ok := action.(policy.ImmediateResponse)
	if !ok {
		t.Fatalf("expected ImmediateResponse, got %T", action)
	}
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("expected 503, got %d", resp.StatusCode)
	}
}

func TestOnRequestHeaders_AuthContextWithNoOrgIDClaim_Returns503(t *testing.T) {
	p, err := GetPolicy(policy.PolicyMetadata{}, nil)
	if err != nil {
		t.Fatalf("GetPolicy failed: %v", err)
	}

	reqCtx := &policy.RequestHeaderContext{
		SharedContext: &policy.SharedContext{
			AuthContext: &policy.AuthContext{Authenticated: true, Properties: map[string]string{}},
		},
		Headers: policy.NewHeaders(map[string][]string{"authorization": {"Bearer caller-token-123"}}),
	}
	action := p.(policy.RequestHeaderPolicy).OnRequestHeaders(context.Background(), reqCtx, nil)

	resp, ok := action.(policy.ImmediateResponse)
	if !ok {
		t.Fatalf("expected ImmediateResponse, got %T", action)
	}
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("expected 503, got %d", resp.StatusCode)
	}
}

func TestOnRequestHeaders_ExchangeFails_Returns502(t *testing.T) {
	exchangeServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer exchangeServer.Close()

	p, err := GetPolicy(policy.PolicyMetadata{}, map[string]interface{}{"exchangeServiceUrl": exchangeServer.URL})
	if err != nil {
		t.Fatalf("GetPolicy failed: %v", err)
	}

	action := p.(policy.RequestHeaderPolicy).OnRequestHeaders(context.Background(), newReqCtx("Railco", "caller-token-123"), nil)

	resp, ok := action.(policy.ImmediateResponse)
	if !ok {
		t.Fatalf("expected ImmediateResponse, got %T", action)
	}
	if resp.StatusCode != http.StatusBadGateway {
		t.Fatalf("expected 502, got %d", resp.StatusCode)
	}
}

func TestGetPolicy_CustomOrgIDClaim(t *testing.T) {
	exchangeServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]string{"access_token": "backend-token-abc"})
	}))
	defer exchangeServer.Close()

	p, err := GetPolicy(policy.PolicyMetadata{}, map[string]interface{}{
		"exchangeServiceUrl": exchangeServer.URL,
		"orgIDClaim":         "organization_id",
	})
	if err != nil {
		t.Fatalf("GetPolicy failed: %v", err)
	}

	reqCtx := &policy.RequestHeaderContext{
		SharedContext: &policy.SharedContext{
			AuthContext: &policy.AuthContext{
				Authenticated: true,
				Properties:    map[string]string{"organization_id": "Acme"},
			},
		},
		Headers: policy.NewHeaders(map[string][]string{"authorization": {"Bearer caller-token-123"}}),
	}
	action := p.(policy.RequestHeaderPolicy).OnRequestHeaders(context.Background(), reqCtx, nil)

	mods, ok := action.(policy.UpstreamRequestHeaderModifications)
	if !ok {
		t.Fatalf("expected UpstreamRequestHeaderModifications, got %T", action)
	}
	if mods.UpstreamName == nil || *mods.UpstreamName != "Acme" {
		t.Fatalf("expected UpstreamName=%q, got %v", "Acme", mods.UpstreamName)
	}
}

func TestGetPolicy_CustomBackendTokenHeader(t *testing.T) {
	exchangeServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]string{"access_token": "backend-token-abc"})
	}))
	defer exchangeServer.Close()

	p, err := GetPolicy(policy.PolicyMetadata{}, map[string]interface{}{
		"exchangeServiceUrl": exchangeServer.URL,
		"backendTokenHeader": "X-Custom-Token",
	})
	if err != nil {
		t.Fatalf("GetPolicy failed: %v", err)
	}

	action := p.(policy.RequestHeaderPolicy).OnRequestHeaders(context.Background(), newReqCtx("Railco", "caller-token-123"), nil)

	mods, ok := action.(policy.UpstreamRequestHeaderModifications)
	if !ok {
		t.Fatalf("expected UpstreamRequestHeaderModifications, got %T", action)
	}
	if got := mods.HeadersToSet["X-Custom-Token"]; got != "Bearer backend-token-abc" {
		t.Fatalf("expected exchanged X-Custom-Token header, got %q", got)
	}
}

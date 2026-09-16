// Package dynamicrouting routes each request to the upstreamDefinitions
// entry named by the caller's org_id, after exchanging the caller's bearer
// token for a backend-specific token via an external exchange service. The
// caller's original Authorization header is dropped; the exchanged token
// is sent to the backend in a separate header instead. No org-to-upstream
// map.
//
// org_id is read from a plain request header (default name "X-Org-Name",
// configurable via the orgIDHeader param) -- jwt-auth (or another auth
// policy) still authenticates the caller's bearer token earlier in the
// chain, but org identity itself comes from this header, not any verified
// token claim. A request with no matching header has no org identity at
// all and is rejected.
package dynamicrouting

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"strings"
	"time"

	policy "github.com/wso2/api-platform/sdk/core/policy/v1alpha2"
)

const (
	defaultOrgIDHeader        = "X-Org-Name"
	defaultExchangeServiceURL = "http://host.docker.internal:7099/exchange"
	defaultTokenField         = "access_token"
	defaultBackendTokenHeader = "X-Backend-Token"
	exchangeTimeout           = 5 * time.Second
)

// DynamicRoutingPolicy holds this policy attachment's configuration. One
// instance is created by GetPolicy and reused across requests.
type DynamicRoutingPolicy struct {
	httpClient         *http.Client
	orgIDHeader        string
	exchangeServiceURL string
	tokenField         string
	backendTokenHeader string
}

// Mode declares this policy only needs to inspect/modify request headers.
func (p *DynamicRoutingPolicy) Mode() policy.ProcessingMode {
	return policy.ProcessingMode{
		RequestHeaderMode:  policy.HeaderModeProcess,
		RequestBodyMode:    policy.BodyModeSkip,
		ResponseHeaderMode: policy.HeaderModeSkip,
		ResponseBodyMode:   policy.BodyModeSkip,
	}
}

// OnRequestHeaders reads the caller's org_id from the orgIDHeader request
// header, exchanges the caller's bearer token for a backend-specific token,
// and routes the request to the upstreamDefinitions entry named after
// org_id. Returns 503 if the header is missing, or 502 if the token
// exchange fails.
func (p *DynamicRoutingPolicy) OnRequestHeaders(
	ctx context.Context,
	reqCtx *policy.RequestHeaderContext,
	params map[string]interface{},
) policy.RequestHeaderAction {
	org := headerValue(reqCtx.Headers, p.orgIDHeader)
	if org == "" {
		log.Printf("[dynamic-routing] no %s header — returning 503", p.orgIDHeader)
		return policy.ImmediateResponse{StatusCode: http.StatusServiceUnavailable}
	}
	log.Printf("[dynamic-routing] org=%s identified from %s header", org, p.orgIDHeader)

	log.Printf("[dynamic-routing] org=%s exchanging caller token via %s", org, p.exchangeServiceURL)
	backendToken, err := p.exchangeToken(ctx, bearerToken(reqCtx.Headers))
	if err != nil {
		log.Printf("[dynamic-routing] org=%s token exchange failed: %v — returning 502", org, err)
		return policy.ImmediateResponse{StatusCode: http.StatusBadGateway}
	}
	log.Printf("[dynamic-routing] org=%s token exchange succeeded, dropping Authorization and setting %s: Bearer %s...", org, p.backendTokenHeader, tokenPrefix(backendToken))

	log.Printf("[dynamic-routing] org=%s routing to upstream=%q (see the [rtr] access-log line below for the actual backend IP:port)", org, org)
	return policy.UpstreamRequestHeaderModifications{
		UpstreamName:    &org,
		HeadersToSet:    map[string]string{p.backendTokenHeader: "Bearer " + backendToken},
		HeadersToRemove: []string{"authorization"},
	}
}

// tokenPrefix returns a short, safe-to-log fragment of a token — enough to
// visually confirm the exchanged token in a demo without ever writing the
// full token to the logs.
func tokenPrefix(token string) string {
	const n = 16
	if len(token) <= n {
		return token
	}
	return token[:n]
}

// bearerToken extracts the raw token from the Authorization header, if any.
func bearerToken(headers *policy.Headers) string {
	values := headers.Get("authorization")
	if len(values) == 0 {
		return ""
	}
	return strings.TrimPrefix(values[0], "Bearer ")
}

// headerValue returns the first value of the given request header, if any.
func headerValue(headers *policy.Headers, name string) string {
	values := headers.Get(strings.ToLower(name))
	if len(values) == 0 {
		return ""
	}
	return values[0]
}

// exchangeToken calls the external exchange service with the caller's token
// and returns the backend-specific token from the configured tokenField.
func (p *DynamicRoutingPolicy) exchangeToken(ctx context.Context, callerToken string) (string, error) {
	body, err := json.Marshal(map[string]string{"token": callerToken})
	if err != nil {
		return "", err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, p.exchangeServiceURL, bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+callerToken)

	resp, err := p.httpClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}
	if resp.StatusCode != http.StatusOK {
		return "", &exchangeError{resp.StatusCode, string(respBody)}
	}

	var parsed map[string]interface{}
	if err := json.Unmarshal(respBody, &parsed); err != nil {
		return "", err
	}
	token, ok := parsed[p.tokenField].(string)
	if !ok || token == "" {
		return "", &exchangeError{resp.StatusCode, "response missing " + p.tokenField}
	}
	return token, nil
}

// exchangeError carries the exchange service's failure status and body.
type exchangeError struct {
	status int
	body   string
}

// Error formats the exchange failure for logging.
func (e *exchangeError) Error() string {
	return "exchange service returned " + http.StatusText(e.status) + ": " + e.body
}

// GetPolicy is the factory called once per policy attachment, building a
// DynamicRoutingPolicy from the attachment's params (or defaults).
func GetPolicy(metadata policy.PolicyMetadata, params map[string]interface{}) (policy.Policy, error) {
	orgIDHeader, _ := params["orgIDHeader"].(string)
	if orgIDHeader == "" {
		orgIDHeader = defaultOrgIDHeader
	}
	exchangeServiceURL, _ := params["exchangeServiceUrl"].(string)
	if exchangeServiceURL == "" {
		exchangeServiceURL = defaultExchangeServiceURL
	}
	tokenField, _ := params["tokenField"].(string)
	if tokenField == "" {
		tokenField = defaultTokenField
	}
	backendTokenHeader, _ := params["backendTokenHeader"].(string)
	if backendTokenHeader == "" {
		backendTokenHeader = defaultBackendTokenHeader
	}

	log.Printf("[dynamic-routing] policy attached: orgIDHeader=%s exchangeServiceUrl=%s tokenField=%s backendTokenHeader=%s", orgIDHeader, exchangeServiceURL, tokenField, backendTokenHeader)

	return &DynamicRoutingPolicy{
		httpClient:         &http.Client{Timeout: exchangeTimeout},
		orgIDHeader:        orgIDHeader,
		exchangeServiceURL: exchangeServiceURL,
		tokenField:         tokenField,
		backendTokenHeader: backendTokenHeader,
	}, nil
}

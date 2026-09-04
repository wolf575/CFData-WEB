package main

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"math/big"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"
)

const autoSpeedURLValue = "auto"

func isIOSMode() bool {
	return os.Getenv("CFDATA_IOS") == "1"
}

const (
	cmSpeedURL              = "cf.090227.xyz/__down?bytes=99999999"
	mobileDedicatedSpeedURL = "speed.okl.abrdns.com"
	cloudflareSpeedURL      = "speed.cloudflare.com/__down?bytes=99999999"
	ispProbeURL             = "https://cf.090227.xyz/cf.json"
)

type ispProbeInfo struct {
	ASN            int    `json:"asn"`
	ASOrganization string `json:"asOrganization"`
}

var autoSpeedURLState = struct {
	sync.RWMutex
	value string
}{value: cloudflareSpeedURL}

func resolveSpeedTestURL(rawURL string) string {
	value := strings.TrimSpace(rawURL)
	if value == "" {
		value = strings.TrimSpace(speedTestURL)
	}
	if strings.EqualFold(value, autoSpeedURLValue) || value == "自动选择" {
		return pickAutoSpeedURL()
	}
	return value
}

func pickAutoSpeedURL() string {
	value := currentAutoSpeedURLDefault()
	if strings.TrimSpace(value) == "" {
		return cloudflareSpeedURL
	}
	return value
}

func currentAutoSpeedURLDefault() string {
	autoSpeedURLState.RLock()
	value := autoSpeedURLState.value
	autoSpeedURLState.RUnlock()
	return value
}

func resolveStartupSpeedTestURL(ctx context.Context, rawURL string) (string, ispProbeInfo, error) {
	value := strings.TrimSpace(rawURL)
	if value == "" {
		value = autoSpeedURLValue
	}
	if isIOSMode() {
		return resolveSpeedTestURL(value), ispProbeInfo{}, nil
	}
	if !isAutoSpeedURL(value) {
		return value, ispProbeInfo{}, nil
	}
	info, err := detectSpeedTestISP(ctx)
	if err != nil {
		return autoSpeedURLValue, info, err
	}
	if isChinaMobileISP(info) {
		setAutoSpeedURLDefault(pickMobileSpeedURL())
		return autoSpeedURLValue, info, nil
	}
	setAutoSpeedURLDefault(cloudflareSpeedURL)
	return autoSpeedURLValue, info, nil
}

func setAutoSpeedURLDefault(value string) {
	autoSpeedURLState.Lock()
	defer autoSpeedURLState.Unlock()
	if strings.TrimSpace(value) == "" {
		autoSpeedURLState.value = cloudflareSpeedURL
		return
	}
	autoSpeedURLState.value = value
}

func isAutoSpeedURL(value string) bool {
	value = strings.TrimSpace(value)
	return strings.EqualFold(value, autoSpeedURLValue) || value == "自动选择"
}

func detectSpeedTestISP(ctx context.Context) (ispProbeInfo, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	data, err := getURLBytesWithContext(ctx, ispProbeURL)
	if err != nil {
		return ispProbeInfo{}, err
	}
	var info ispProbeInfo
	if err := json.Unmarshal(data, &info); err != nil {
		return ispProbeInfo{}, err
	}
	return info, nil
}

func isChinaMobileISP(info ispProbeInfo) bool {
	org := strings.ToLower(info.ASOrganization)
	mobileKeywords := []string{"cmi", "cmnet", "chinamobile", "china mobile", "cmcc", "mobile communications", "移动"}
	for _, keyword := range mobileKeywords {
		if strings.Contains(org, keyword) {
			return true
		}
	}
	switch info.ASN {
	case 9808, 24400, 56040, 56041, 56044:
		return true
	default:
		return false
	}
}

func pickMobileSpeedURL() string {
	urls := []string{cmSpeedURL, mobileDedicatedSpeedURL}
	idx := 0
	if n, err := rand.Int(rand.Reader, big.NewInt(int64(len(urls)))); err == nil {
		idx = int(n.Int64())
	}
	return urls[idx]
}

func warmStartupSpeedTestURL() {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	resolvedSpeedURL, speedISP, err := resolveStartupSpeedTestURL(ctx, speedTestURL)
	if err != nil {
		recordDebugError("speed_isp_check", err.Error())
		return
	}
	recordDebugByLevel("all", "speed_isp_check", fmt.Sprintf("startup asn=%d org=%s mobile=%v selected=%s", speedISP.ASN, speedISP.ASOrganization, isChinaMobileISP(speedISP), resolvedSpeedURL))
}

func parseSpeedTestURL(rawURL string, fallbackScheme string) (*url.URL, error) {
	value := resolveSpeedTestURL(rawURL)
	if strings.TrimSpace(value) == "" {
		return nil, fmt.Errorf("测速地址为空")
	}

	fallbackScheme = strings.TrimSuffix(strings.ToLower(strings.TrimSpace(fallbackScheme)), "://")
	if fallbackScheme != "http" && fallbackScheme != "https" {
		fallbackScheme = "https"
	}

	lowerValue := strings.ToLower(value)
	if strings.HasPrefix(value, "//") {
		value = fallbackScheme + ":" + value
	} else if !strings.HasPrefix(lowerValue, "http://") && !strings.HasPrefix(lowerValue, "https://") {
		value = fallbackScheme + "://" + value
	}

	parsed, err := url.Parse(value)
	if err != nil {
		return nil, err
	}
	parsed.Scheme = strings.ToLower(parsed.Scheme)
	if parsed.Scheme != "http" && parsed.Scheme != "https" {
		return nil, fmt.Errorf("不支持的测速地址协议: %s", parsed.Scheme)
	}
	if strings.TrimSpace(parsed.Hostname()) == "" {
		return nil, fmt.Errorf("测速地址缺少域名")
	}
	if parsed.Path == "" {
		parsed.Path = "/"
	}
	return parsed, nil
}

package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const (
	runtimeLogMaxLines = 600
	runtimeLogMaxBytes = int64(256 * 1024)
)

type runtimeLogEntry struct {
	Time   string `json:"time"`
	Level  string `json:"level"`
	Source string `json:"source"`
	Detail string `json:"detail"`
}

var runtimeLogState = struct {
	sync.Mutex
	lines                []runtimeLogEntry
	httpClientConfigured bool
}{}

var processStartTime = time.Now()

func runtimeLog(level, source, detail string) {
	line := runtimeLogEntry{
		Time:   time.Now().Format(time.RFC3339Nano),
		Level:  level,
		Source: source,
		Detail: strings.TrimSpace(detail),
	}
	runtimeLogState.Lock()
	runtimeLogState.lines = append(runtimeLogState.lines, line)
	if len(runtimeLogState.lines) > runtimeLogMaxLines {
		runtimeLogState.lines = runtimeLogState.lines[len(runtimeLogState.lines)-runtimeLogMaxLines:]
	}
	runtimeLogState.Unlock()
	fmt.Printf("[runtime] %s level=%s source=%s detail=%s\n", line.Time, level, source, line.Detail)
}

func markHTTPClientConfigured() {
	runtimeLogState.Lock()
	runtimeLogState.httpClientConfigured = true
	runtimeLogState.Unlock()
	runtimeLog("info", "http_client", "configured")
}

func handleHealthCheck(w http.ResponseWriter, r *http.Request) {
	runtimeLogState.Lock()
	httpClientConfigured := runtimeLogState.httpClientConfigured
	runtimeLogState.Unlock()

	cwd, _ := os.Getwd()
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_ = json.NewEncoder(w).Encode(map[string]interface{}{
		"ok":                   true,
		"version":              appVersion,
		"pid":                  os.Getpid(),
		"uptime":               time.Since(processStartTime).String(),
		"cwd":                  cwd,
		"iosMode":              os.Getenv("CFDATA_IOS") == "1",
		"httpClientConfigured": httpClientConfigured,
	})
}

func handleRuntimeDiagnostics(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_ = json.NewEncoder(w).Encode(runtimeDiagnosticsSnapshot())
}

func handleRuntimeLog(w http.ResponseWriter, r *http.Request) {
	lines := runtimeLogTextLines()
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	_, _ = w.Write([]byte(strings.Join(lines, "\n")))
}

func runtimeDiagnosticsSnapshot() map[string]interface{} {
	runtimeLogState.Lock()
	logLines := append([]runtimeLogEntry(nil), runtimeLogState.lines...)
	httpClientConfigured := runtimeLogState.httpClientConfigured
	runtimeLogState.Unlock()

	locationMapMu.RLock()
	locationsLoaded := locationMap != nil
	locationCount := len(locationMap)
	locationMapMu.RUnlock()

	cwd, _ := os.Getwd()
	exe, _ := os.Executable()
	stdoutLogPath := filepath.Join(cwd, "cfdata.log")
	debugLogPath := defaultDebugLogPath()

	return map[string]interface{}{
		"ok":                   true,
		"version":              appVersion,
		"pid":                  os.Getpid(),
		"uptime":               time.Since(processStartTime).String(),
		"cwd":                  cwd,
		"executable":           exe,
		"args":                 os.Args,
		"iosMode":              os.Getenv("CFDATA_IOS") == "1",
		"host":                 listenHost,
		"port":                 listenPort,
		"speedTestURL":         speedTestURL,
		"resolvedSpeedTestURL": resolveSpeedTestURL(speedTestURL),
		"skipGeoCheck":         skipGeoCheck,
		"debugMode":            debugMode,
		"debugLevel":           debugLevel,
		"httpClientConfigured": httpClientConfigured,
		"locationsLoaded":      locationsLoaded,
		"locationCount":        locationCount,
		"stdoutLogPath":        stdoutLogPath,
		"stdoutLogTail":        tailTextFile(stdoutLogPath, 80),
		"debugLogPath":         debugLogPath,
		"debugLogTail":         tailTextFile(debugLogPath, 80),
		"runtimeLog":           logLines,
	}
}

func runtimeLogTextLines() []string {
	diagnostics := runtimeDiagnosticsSnapshot()
	lines := make([]string, 0, 260)

	if logEntries, ok := diagnostics["runtimeLog"].([]runtimeLogEntry); ok {
		for _, entry := range logEntries {
			lines = append(lines, fmt.Sprintf("[%s] %s source=%s detail=%s", entry.Time, entry.Level, entry.Source, entry.Detail))
		}
	}
	lines = append(lines, "")
	lines = append(lines, "=== stdout log ("+fmt.Sprint(diagnostics["stdoutLogPath"])+") ===")
	if tail, ok := diagnostics["stdoutLogTail"].([]string); ok {
		lines = append(lines, tail...)
	}
	lines = append(lines, "")
	lines = append(lines, "=== debug log ("+fmt.Sprint(diagnostics["debugLogPath"])+") ===")
	if tail, ok := diagnostics["debugLogTail"].([]string); ok {
		lines = append(lines, tail...)
	}
	return lines
}

func tailTextFile(path string, maxLines int) []string {
	if strings.TrimSpace(path) == "" {
		return nil
	}
	file, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer file.Close()

	info, err := file.Stat()
	if err != nil {
		return nil
	}
	start := int64(0)
	if info.Size() > runtimeLogMaxBytes {
		start = info.Size() - runtimeLogMaxBytes
	}
	if _, err := file.Seek(start, 0); err != nil {
		return nil
	}

	buf := make([]byte, info.Size()-start)
	n, _ := file.Read(buf)
	rawLines := strings.Split(string(buf[:n]), "\n")
	filtered := make([]string, 0, len(rawLines))
	for _, line := range rawLines {
		if strings.TrimSpace(line) != "" {
			filtered = append(filtered, strings.TrimSpace(line))
		}
	}
	if len(filtered) > maxLines {
		filtered = filtered[len(filtered)-maxLines:]
	}
	return filtered
}

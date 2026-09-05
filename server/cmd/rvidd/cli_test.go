package main_test

import (
	"encoding/json"
	"os/exec"
	"testing"
)

func TestVersionCommandReportsBinaryAndProtocolVersions(t *testing.T) {
	command := exec.Command("go", "run", ".", "version", "--json")
	output, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("rvidd version --json failed: %v\n%s", err, output)
	}

	var version struct {
		Version  string `json:"version"`
		Protocol int    `json:"protocol"`
	}
	if err := json.Unmarshal(output, &version); err != nil {
		t.Fatalf("decode version JSON: %v\n%s", err, output)
	}
	if version.Version != "0.1.0" || version.Protocol != 1 {
		t.Fatalf("unexpected version response: %+v", version)
	}
}

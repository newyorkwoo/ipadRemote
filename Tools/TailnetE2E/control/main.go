// 本機測試用的 Tailscale 控制伺服器 + DERP/STUN（不需要 Tailscale 帳號，節點自動核准）。
// 印出控制伺服器網址後持續執行，直到 stdin 關閉。僅供 Tools/TailnetE2E 測試使用。
package main

import (
	"fmt"
	"io"
	"net/http/httptest"
	"os"
	"testing"

	"tailscale.com/net/netns"
	"tailscale.com/tstest/integration"
	"tailscale.com/tstest/integration/testcontrol"
	"tailscale.com/types/logger"
)

func main() {
	netns.SetEnabled(false)
	testing.Init()
	var t fakeTB
	derpMap := integration.RunDERPAndSTUN(&t, logger.Discard, "127.0.0.1")
	control := &testcontrol.Server{DERPMap: derpMap}
	control.HTTPTestServer = httptest.NewUnstartedServer(control)
	control.HTTPTestServer.Start()
	fmt.Println(control.HTTPTestServer.URL)
	io.Copy(io.Discard, os.Stdin)
}

type fakeTB struct{ testing.TB }

func (fakeTB) Cleanup(func())                {}
func (fakeTB) Helper()                       {}
func (fakeTB) Name() string                  { return "tailnet-e2e" }
func (fakeTB) Logf(string, ...any)           {}
func (fakeTB) Log(...any)                    {}
func (fakeTB) Errorf(f string, a ...any)     { fmt.Fprintf(os.Stderr, f+"\n", a...) }
func (fakeTB) Error(a ...any)                { fmt.Fprintln(os.Stderr, a...) }
func (fakeTB) Fatalf(f string, a ...any)     { fmt.Fprintf(os.Stderr, f+"\n", a...); os.Exit(1) }
func (fakeTB) Fatal(a ...any)                { fmt.Fprintln(os.Stderr, a...); os.Exit(1) }
func (fakeTB) Fail()                         {}
func (fakeTB) FailNow()                      { os.Exit(1) }
func (fakeTB) Failed() bool                  { return false }
func (fakeTB) Skip(...any)                   {}
func (fakeTB) Skipf(string, ...any)          {}
func (fakeTB) SkipNow()                      {}
func (fakeTB) Skipped() bool                 { return false }
func (fakeTB) TempDir() string               { d, _ := os.MkdirTemp("", "tse2e"); return d }
func (fakeTB) Setenv(string, string)         {}

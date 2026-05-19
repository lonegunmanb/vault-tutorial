// 一个尽量精简的 Go 网站，演示 9.9 节里描述的 Vault Login MFA 两阶段登录流。
//
// 整个应用只有三条 HTTP 路由：
//
//   GET  /            登录页（用户名 + 密码表单）
//   POST /login       第一阶段：把用户名 / 密码丢给 Vault 的 LDAP 认证方法
//                     - 如果命中了 Login Enforcement，Vault 会返回一个
//                       mfa_requirement.mfa_request_id；本应用把它存进
//                       服务端 session、跳转到 /mfa
//                     - 如果没命中 MFA，直接拿到 client_token，跳 /protected
//   GET  /mfa         OTP 输入页
//   POST /mfa         第二阶段：把 OTP + mfa_request_id 提交给
//                     /v1/sys/mfa/validate，换回 Vault Client Token
//   GET  /protected   登录成功后才能访问的页面，显示 entity_id / policies
//   POST /logout      调 auth/token/revoke-self 主动撤销 token，清 cookie
//
// 与 Vault 通信只用 net/http，没有引入任何 Vault SDK，方便直接看到
// "网站和 Vault 之间到底交换了哪些 HTTP 报文"。
//
// 环境变量：
//   VAULT_ADDR       Vault 地址，默认 http://127.0.0.1:8200
//   TOTP_METHOD_ID   sys/mfa/method/totp/my-totp 的 method_id（UUID）
//   APP_ADDR         监听地址，默认 :8080
package main

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"html/template"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

// ─────────────────────────────── 服务端 Session ───────────────────────────────
//
// 内存里的最简实现：sid -> session 结构。生产里要换成 Redis / 数据库 + TTL，
// 这里只为演示。session 里同时承载两类状态：
//   - 第一阶段成功后、第二阶段未完成：保留 MFARequestID
//   - 第二阶段成功后：保留 Vault 颁发的 client_token

type session struct {
	Username     string
	MFARequestID string    // 第一阶段拿到、第二阶段用掉，用完即清
	Token        string    // 第二阶段拿到的 Vault Client Token（注意：不会出现在 cookie 里）
	EntityID     string
	Policies     []string
	CreatedAt    time.Time
}

var (
	sessMu   sync.Mutex
	sessions = map[string]*session{}
)

func newSID() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

func putSession(s *session) string {
	sid := newSID()
	sessMu.Lock()
	defer sessMu.Unlock()
	s.CreatedAt = time.Now()
	sessions[sid] = s
	return sid
}

func getSession(r *http.Request) (string, *session) {
	c, err := r.Cookie("sid")
	if err != nil {
		return "", nil
	}
	sessMu.Lock()
	defer sessMu.Unlock()
	return c.Value, sessions[c.Value]
}

func dropSession(sid string) {
	sessMu.Lock()
	defer sessMu.Unlock()
	delete(sessions, sid)
}

func setSidCookie(w http.ResponseWriter, sid string) {
	http.SetCookie(w, &http.Cookie{
		Name: "sid", Value: sid, Path: "/", HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
	})
}

// ─────────────────────────────── Vault HTTP ───────────────────────────────

func vaultAddr() string {
	a := os.Getenv("VAULT_ADDR")
	if a == "" {
		a = "http://127.0.0.1:8200"
	}
	return strings.TrimRight(a, "/")
}

// vaultPOST 发送一次 POST 到 Vault；body 会被 JSON 编码；
// token 为空时不带 X-Vault-Token（unauthenticated 调用，如 ldap/login、sys/mfa/validate）。
// 返回 (status, 解析后的 JSON, error)；HTTP >=400 仍然解析 body 以便上层看 errors 字段。
func vaultPOST(path string, body any, token string) (int, map[string]any, error) {
	var reader io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		reader = bytes.NewReader(b)
	}
	req, _ := http.NewRequest("POST", vaultAddr()+path, reader)
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("X-Vault-Token", token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	var out map[string]any
	if len(raw) > 0 {
		_ = json.Unmarshal(raw, &out)
	}
	return resp.StatusCode, out, nil
}

func vaultErrors(out map[string]any) string {
	if out == nil {
		return "(empty response)"
	}
	if errs, ok := out["errors"].([]any); ok && len(errs) > 0 {
		parts := []string{}
		for _, e := range errs {
			parts = append(parts, fmt.Sprint(e))
		}
		return strings.Join(parts, "; ")
	}
	b, _ := json.Marshal(out)
	return string(b)
}

// ─────────────────────────────── 模板 ───────────────────────────────

var tpls = template.Must(template.New("").Parse(`
{{define "layout"}}<!doctype html>
<html><head><meta charset="utf-8"><title>{{.Title}}</title>
<style>
body{font-family:sans-serif;max-width:560px;margin:40px auto;padding:0 16px;color:#222}
h1{font-size:20px}label{display:block;margin-top:12px}
input{font-size:14px;padding:6px 8px;width:100%;box-sizing:border-box}
button{margin-top:16px;padding:8px 16px;font-size:14px;cursor:pointer}
.err{color:#a00;background:#fee;padding:8px;border-radius:4px;margin:12px 0}
.note{color:#555;font-size:13px;background:#f4f4f4;padding:10px;border-radius:4px;margin:12px 0}
pre{background:#f4f4f4;padding:10px;border-radius:4px;overflow:auto;font-size:12px}
</style></head><body>
<h1>{{.Title}}</h1>
{{if .Err}}<div class="err">{{.Err}}</div>{{end}}
{{template "body" .}}
</body></html>{{end}}

{{define "login"}}{{template "layout" .}}{{end}}
{{define "body_login"}}
<div class="note">第一阶段：把用户名/密码交给 Vault 的 LDAP 认证方法。<br>
如果该挂载点配了 Login Enforcement，Vault 会回一个 mfa_request_id，把你引到下一页。</div>
<form method="POST" action="/login">
  <label>LDAP Username<input name="username" autofocus></label>
  <label>Password<input name="password" type="password"></label>
  <button type="submit">登录</button>
</form>
{{end}}

{{define "mfa"}}{{template "layout" .}}{{end}}
{{define "body_mfa"}}
<div class="note">第二阶段：你的 LDAP 密码已被 Vault 接受。<br>
请打开 Authenticator App（或在终端用 oathtool）输入当前 6 位验证码。<br>
mfa_request_id 是一次性的：输错就要回 /login 重来。</div>
<form method="POST" action="/mfa">
  <label>6 位 TOTP 验证码<input name="otp" inputmode="numeric" pattern="[0-9]{6}" autofocus></label>
  <button type="submit">提交</button>
</form>
{{end}}

{{define "protected"}}{{template "layout" .}}{{end}}
{{define "body_protected"}}
<div class="note">登录成功。下面这些字段都是 Vault /sys/mfa/validate 响应里返回的，
被网站后端存进了服务端 session；浏览器从未直接接触 Vault Token。</div>
<pre>username:  {{.Username}}
entity_id: {{.EntityID}}
policies:  {{.Policies}}
</pre>
<form method="POST" action="/logout"><button type="submit">登出（revoke-self）</button></form>
{{end}}
`))

func render(w http.ResponseWriter, name string, data map[string]any) {
	data["Title"] = data["Title"].(string)
	// 两层模板：先选 body_<name>，再套 layout
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	wrap := template.Must(template.Must(tpls.Clone()).Parse(
		`{{define "body"}}{{template "body_` + name + `" .}}{{end}}`))
	if err := wrap.ExecuteTemplate(w, name, data); err != nil {
		log.Printf("render %s: %v", name, err)
	}
}

// ─────────────────────────────── Handlers ───────────────────────────────

func handleIndex(w http.ResponseWriter, r *http.Request) {
	// 已登录就直接跳保护页
	if _, s := getSession(r); s != nil && s.Token != "" {
		http.Redirect(w, r, "/protected", http.StatusSeeOther)
		return
	}
	render(w, "login", map[string]any{"Title": "登录 — Vault LDAP + TOTP 网关示例"})
}

func handleLogin(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Redirect(w, r, "/", http.StatusSeeOther)
		return
	}
	u := strings.TrimSpace(r.FormValue("username"))
	p := r.FormValue("password")
	if u == "" || p == "" {
		render(w, "login", map[string]any{
			"Title": "登录", "Err": "用户名或密码不能为空",
		})
		return
	}

	// 第一阶段：POST /v1/auth/ldap/login/<username> {password}
	status, out, err := vaultPOST("/v1/auth/ldap/login/"+u,
		map[string]string{"password": p}, "")
	if err != nil || status >= 400 {
		msg := "LDAP 校验失败"
		if out != nil {
			msg += "：" + vaultErrors(out)
		}
		render(w, "login", map[string]any{"Title": "登录", "Err": msg})
		return
	}

	auth, _ := out["auth"].(map[string]any)
	if auth == nil {
		render(w, "login", map[string]any{"Title": "登录",
			"Err": "Vault 响应里没有 auth 字段：" + vaultErrors(out)})
		return
	}

	// 分支一：MFA 强制 —— 进入第二阶段
	if mfa, ok := auth["mfa_requirement"].(map[string]any); ok {
		sid := putSession(&session{
			Username:     u,
			MFARequestID: mfa["mfa_request_id"].(string),
		})
		setSidCookie(w, sid)
		http.Redirect(w, r, "/mfa", http.StatusSeeOther)
		return
	}

	// 分支二：没强制 MFA —— 第一阶段就拿到 token 了
	tok, _ := auth["client_token"].(string)
	if tok == "" {
		render(w, "login", map[string]any{"Title": "登录",
			"Err": "Vault 既没回 mfa_requirement 也没回 client_token，配置异常"})
		return
	}
	finish(w, r, u, tok, auth)
}

func handleMFAGet(w http.ResponseWriter, r *http.Request) {
	_, s := getSession(r)
	if s == nil || s.MFARequestID == "" {
		http.Redirect(w, r, "/", http.StatusSeeOther)
		return
	}
	render(w, "mfa", map[string]any{"Title": "MFA — 输入 TOTP"})
}

func handleMFAPost(w http.ResponseWriter, r *http.Request) {
	sid, s := getSession(r)
	if s == nil || s.MFARequestID == "" {
		http.Redirect(w, r, "/", http.StatusSeeOther)
		return
	}
	otp := strings.TrimSpace(r.FormValue("otp"))
	methodID := os.Getenv("TOTP_METHOD_ID")
	if methodID == "" {
		render(w, "mfa", map[string]any{"Title": "MFA",
			"Err": "服务器没配 TOTP_METHOD_ID 环境变量"})
		return
	}

	// 第二阶段：POST /v1/sys/mfa/validate {mfa_request_id, mfa_payload}
	// 注意 mfa_payload 的 key 必须是 method 的 UUID，而不是它的好记名字
	body := map[string]any{
		"mfa_request_id": s.MFARequestID,
		"mfa_payload":    map[string][]string{methodID: {otp}},
	}
	status, out, err := vaultPOST("/v1/sys/mfa/validate", body, "")
	if err != nil || status >= 400 {
		// mfa_request_id 是一次性的：失败了必须回 /login 重走第一阶段
		dropSession(sid)
		http.SetCookie(w, &http.Cookie{Name: "sid", Value: "", Path: "/", MaxAge: -1})
		msg := "MFA 校验失败，请重新登录"
		if out != nil {
			msg += "：" + vaultErrors(out)
		}
		render(w, "login", map[string]any{"Title": "登录", "Err": msg})
		return
	}

	auth, _ := out["auth"].(map[string]any)
	tok, _ := auth["client_token"].(string)
	if tok == "" {
		render(w, "login", map[string]any{"Title": "登录",
			"Err": "MFA 通过但没拿到 token：" + vaultErrors(out)})
		return
	}
	finish(w, r, s.Username, tok, auth)
}

// finish 把第二阶段（或没启 MFA 时的第一阶段）拿到的 token 放进 session，
// 清掉 mfa_request_id，跳转到保护页。
func finish(w http.ResponseWriter, r *http.Request, user, token string, auth map[string]any) {
	sid, s := getSession(r)
	if s == nil {
		s = &session{Username: user}
		sid = putSession(s)
		setSidCookie(w, sid)
	}
	s.Token = token
	s.MFARequestID = ""
	if v, ok := auth["entity_id"].(string); ok {
		s.EntityID = v
	}
	if ps, ok := auth["policies"].([]any); ok {
		for _, p := range ps {
			s.Policies = append(s.Policies, fmt.Sprint(p))
		}
	}
	http.Redirect(w, r, "/protected", http.StatusSeeOther)
}

func handleProtected(w http.ResponseWriter, r *http.Request) {
	_, s := getSession(r)
	if s == nil || s.Token == "" {
		http.Redirect(w, r, "/", http.StatusSeeOther)
		return
	}
	render(w, "protected", map[string]any{
		"Title":    "受保护页面",
		"Username": s.Username,
		"EntityID": s.EntityID,
		"Policies": s.Policies,
	})
}

func handleLogout(w http.ResponseWriter, r *http.Request) {
	sid, s := getSession(r)
	if s != nil && s.Token != "" {
		// 主动撤 token，缩短泄漏窗口
		_, _, _ = vaultPOST("/v1/auth/token/revoke-self", nil, s.Token)
	}
	if sid != "" {
		dropSession(sid)
	}
	http.SetCookie(w, &http.Cookie{Name: "sid", Value: "", Path: "/", MaxAge: -1})
	http.Redirect(w, r, "/", http.StatusSeeOther)
}

// ─────────────────────────────── main ───────────────────────────────

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/", handleIndex)
	mux.HandleFunc("/login", handleLogin)
	mux.HandleFunc("/mfa", func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodPost:
			handleMFAPost(w, r)
		default:
			handleMFAGet(w, r)
		}
	})
	mux.HandleFunc("/protected", handleProtected)
	mux.HandleFunc("/logout", handleLogout)

	addr := os.Getenv("APP_ADDR")
	if addr == "" {
		addr = ":8080"
	}
	log.Printf("listening on %s, VAULT_ADDR=%s", addr, vaultAddr())
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatal(err)
	}
}

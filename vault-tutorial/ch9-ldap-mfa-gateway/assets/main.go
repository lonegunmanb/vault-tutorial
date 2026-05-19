// 一个尽量精简的 Go 网站，演示 Vault OSS 下的 LDAP + TOTP 两阶段登录编排。
//
// Vault OSS 没有 Enterprise Login MFA 的 /sys/mfa 自动拦截器，所以网站后端
// 自己串起两个 Vault 能力：
//
//	GET  /            登录页（用户名 + 密码表单）
//	POST /login       第一阶段：把用户名 / 密码丢给 Vault 的 LDAP 认证方法。
//	                  Vault OSS 会立即返回 client_token；本应用先把它扣在
//	                  服务端 pending session 中，不把用户视为已登录。
//	GET  /mfa         OTP 输入页
//	POST /mfa         第二阶段：用 pending token 调 /v1/totp/code/<username>
//	                  验证 OTP。valid=true 后才把 pending token 提升为正式
//	                  登录 session；失败或超时则 revoke pending token。
//	GET  /protected   登录成功后才能访问的页面，显示 entity_id / policies
//	POST /logout      调 auth/token/revoke-self 主动撤销 token，清 cookie
//
// 与 Vault 通信只用 net/http，没有引入任何 Vault SDK，方便直接看到
// "网站和 Vault 之间到底交换了哪些 HTTP 报文"。
//
// 环境变量：
//
//	VAULT_ADDR       Vault 地址，默认 http://127.0.0.1:8200
//	APP_ADDR         监听地址，默认 :8080
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
	"net/url"
	"os"
	"strings"
	"sync"
	"time"
)

const pendingTTL = 5 * time.Minute

type session struct {
	Username     string
	PendingToken string
	Token        string
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
		Name:     "sid",
		Value:    sid,
		Path:     "/",
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
	})
}

func clearSidCookie(w http.ResponseWriter) {
	http.SetCookie(w, &http.Cookie{Name: "sid", Value: "", Path: "/", MaxAge: -1})
}

func vaultAddr() string {
	a := os.Getenv("VAULT_ADDR")
	if a == "" {
		a = "http://127.0.0.1:8200"
	}
	return strings.TrimRight(a, "/")
}

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

func dataMap(out map[string]any) map[string]any {
	d, _ := out["data"].(map[string]any)
	return d
}

func revokeToken(token string) {
	if token == "" {
		return
	}
	_, _, _ = vaultPOST("/v1/auth/token/revoke-self", nil, token)
}

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
<div class="note">第一阶段：网站把用户名/密码交给 Vault LDAP auth。Vault OSS 会立即发 token；本网站先把它扣在服务端 pending session 中，等第二阶段 TOTP 通过后才算登录完成。</div>
<form method="POST" action="/login">
  <label>LDAP Username<input name="username" autofocus></label>
  <label>Password<input name="password" type="password"></label>
  <button type="submit">登录</button>
</form>
{{end}}

{{define "mfa"}}{{template "layout" .}}{{end}}
{{define "body_mfa"}}
<div class="note">第二阶段：LDAP 密码已被 Vault 接受，但 token 仍只在服务端 pending session 中。请输入 Authenticator App 当前显示的 6 位验证码，网站会调用 Vault 的 totp/code/{{.Username}} 进行校验。</div>
<form method="POST" action="/mfa">
  <label>6 位 TOTP 验证码<input name="otp" inputmode="numeric" pattern="[0-9]{6}" autofocus></label>
  <button type="submit">提交</button>
</form>
{{end}}

{{define "protected"}}{{template "layout" .}}{{end}}
{{define "body_protected"}}
<div class="note">登录成功。Vault token 保存在网站服务端 session；浏览器只拿到本站自己的 sid Cookie。</div>
<pre>username:  {{.Username}}
entity_id: {{.EntityID}}
policies:  {{.Policies}}
</pre>
<form method="POST" action="/logout"><button type="submit">登出（revoke-self）</button></form>
{{end}}
`))

func render(w http.ResponseWriter, name string, data map[string]any) {
	data["Title"] = data["Title"].(string)
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	wrap := template.Must(template.Must(tpls.Clone()).Parse(
		`{{define "body"}}{{template "body_` + name + `" .}}{{end}}`))
	if err := wrap.ExecuteTemplate(w, name, data); err != nil {
		log.Printf("render %s: %v", name, err)
	}
}

func handleIndex(w http.ResponseWriter, r *http.Request) {
	if _, s := getSession(r); s != nil && s.Token != "" {
		http.Redirect(w, r, "/protected", http.StatusSeeOther)
		return
	}
	render(w, "login", map[string]any{"Title": "登录 - Vault OSS LDAP + TOTP 网关示例"})
}

func handleLogin(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Redirect(w, r, "/", http.StatusSeeOther)
		return
	}
	u := strings.TrimSpace(r.FormValue("username"))
	p := r.FormValue("password")
	if u == "" || p == "" {
		render(w, "login", map[string]any{"Title": "登录", "Err": "用户名或密码不能为空"})
		return
	}

	status, out, err := vaultPOST("/v1/auth/ldap/login/"+url.PathEscape(u), map[string]string{"password": p}, "")
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
		render(w, "login", map[string]any{"Title": "登录", "Err": "Vault 响应里没有 auth 字段：" + vaultErrors(out)})
		return
	}
	tok, _ := auth["client_token"].(string)
	if tok == "" {
		render(w, "login", map[string]any{"Title": "登录", "Err": "Vault LDAP 登录没有返回 client_token：" + vaultErrors(out)})
		return
	}

	s := &session{Username: u, PendingToken: tok}
	if v, ok := auth["entity_id"].(string); ok {
		s.EntityID = v
	}
	if ps, ok := auth["policies"].([]any); ok {
		for _, p := range ps {
			s.Policies = append(s.Policies, fmt.Sprint(p))
		}
	}
	sid := putSession(s)
	setSidCookie(w, sid)
	log.Printf("first factor accepted for %s; token is pending MFA", u)
	http.Redirect(w, r, "/mfa", http.StatusSeeOther)
}

func handleMFAGet(w http.ResponseWriter, r *http.Request) {
	_, s := getSession(r)
	if s == nil || s.PendingToken == "" {
		http.Redirect(w, r, "/", http.StatusSeeOther)
		return
	}
	render(w, "mfa", map[string]any{"Title": "MFA - 输入 TOTP", "Username": s.Username})
}

func failPending(w http.ResponseWriter, sid string, s *session, msg string) {
	if s != nil {
		revokeToken(s.PendingToken)
	}
	if sid != "" {
		dropSession(sid)
	}
	clearSidCookie(w)
	render(w, "login", map[string]any{"Title": "登录", "Err": msg})
}

func handleMFAPost(w http.ResponseWriter, r *http.Request) {
	sid, s := getSession(r)
	if s == nil || s.PendingToken == "" {
		http.Redirect(w, r, "/", http.StatusSeeOther)
		return
	}
	if time.Since(s.CreatedAt) > pendingTTL {
		failPending(w, sid, s, "MFA 流程已超时，请重新登录")
		return
	}
	otp := strings.TrimSpace(r.FormValue("otp"))
	if otp == "" {
		render(w, "mfa", map[string]any{"Title": "MFA", "Username": s.Username, "Err": "验证码不能为空"})
		return
	}

	status, out, err := vaultPOST("/v1/totp/code/"+url.PathEscape(s.Username), map[string]string{"code": otp}, s.PendingToken)
	if err != nil || status >= 400 {
		msg := "TOTP 校验失败，请重新登录"
		if out != nil {
			msg += "：" + vaultErrors(out)
		}
		failPending(w, sid, s, msg)
		return
	}
	valid, _ := dataMap(out)["valid"].(bool)
	if !valid {
		failPending(w, sid, s, "TOTP 校验失败，请重新登录")
		return
	}

	s.Token = s.PendingToken
	s.PendingToken = ""
	log.Printf("second factor accepted for %s; pending token promoted", s.Username)
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
	if s != nil {
		revokeToken(s.Token)
		revokeToken(s.PendingToken)
	}
	if sid != "" {
		dropSession(sid)
	}
	clearSidCookie(w)
	http.Redirect(w, r, "/", http.StatusSeeOther)
}

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

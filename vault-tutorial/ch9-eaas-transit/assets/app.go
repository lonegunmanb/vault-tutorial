// 一个最小可运行的 Gin Web 应用，与 HashiCorp 官方 Spring Cloud 演示
//   hashicorp-education/learn-vault-spring-cloud / vault-transit
// 在外部行为上严格一致，只把实现语言从 Java + Spring Boot 换成 Go + Gin：
//
//   GET  /payments      列出所有支付记录；每条 cc_info 通过 Vault transit/decrypt
//                       从数据库里的密文还原成明文一并返回；
//   POST /payments      接收 {"name":"...","cc_info":"..."}（客户端不传 id 与
//                       created_at），把 cc_info 通过 transit/encrypt 加密成
//                       vault:vN:... 字符串后写入 PostgreSQL；返回包含刚插入这
//                       一条记录的数组（与官方 Java 版本的返回格式一致）；
//   POST /admin/rewrap  本节自加的运维端点：遍历 payments 表，对每条 cc_info
//                       调用 transit/rewrap 把旧版本密文升级到当前最新密钥版本。
//
// 与 Vault 通信用 net/http 直连 REST API（不引入任何 Vault SDK），通过两个环境
// 变量配置：
//   VAULT_ADDR    例如 http://127.0.0.1:8200
//   VAULT_TOKEN   应用 Token（实验里 step3 演示如何用最小权限 Token 替换）
// 与 PostgreSQL 通信用一个环境变量配置：
//   DATABASE_URL  例如 postgres://postgres:postgres-admin-password@127.0.0.1:5432/payments?sslmode=disable

package main

import (
	"bytes"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	_ "github.com/lib/pq"
)

const keyName = "payments"

type Payment struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	CCInfo    string    `json:"cc_info"`
	CreatedAt time.Time `json:"createdAt"`
}

var db *sql.DB

// ---------------- Vault HTTP 调用工具 ----------------

func vaultAddr() string {
	a := os.Getenv("VAULT_ADDR")
	if a == "" {
		a = "http://127.0.0.1:8200"
	}
	return a
}

func vaultCall(path string, body map[string]string) (map[string]any, error) {
	var reader io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		reader = bytes.NewReader(b)
	}
	req, _ := http.NewRequest("POST", vaultAddr()+"/v1/"+path, reader)
	req.Header.Set("X-Vault-Token", os.Getenv("VAULT_TOKEN"))
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 400 {
		return nil, fmt.Errorf("vault %s -> HTTP %d: %s", path, resp.StatusCode, string(raw))
	}
	var out map[string]any
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil, err
	}
	return out, nil
}

func vaultDataString(out map[string]any, field string) (string, error) {
	d, ok := out["data"].(map[string]any)
	if !ok {
		return "", fmt.Errorf("vault response missing data")
	}
	v, ok := d[field].(string)
	if !ok {
		return "", fmt.Errorf("vault response missing data.%s", field)
	}
	return v, nil
}

func encryptCC(plain string) (string, error) {
	b64 := base64.StdEncoding.EncodeToString([]byte(plain))
	out, err := vaultCall("transit/encrypt/"+keyName, map[string]string{"plaintext": b64})
	if err != nil {
		return "", err
	}
	return vaultDataString(out, "ciphertext")
}

func decryptCC(cipher string) (string, error) {
	out, err := vaultCall("transit/decrypt/"+keyName, map[string]string{"ciphertext": cipher})
	if err != nil {
		return "", err
	}
	b64, err := vaultDataString(out, "plaintext")
	if err != nil {
		return "", err
	}
	raw, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		return "", err
	}
	return string(raw), nil
}

func rewrapCC(cipher string) (string, error) {
	out, err := vaultCall("transit/rewrap/"+keyName, map[string]string{"ciphertext": cipher})
	if err != nil {
		return "", err
	}
	return vaultDataString(out, "ciphertext")
}

// ---------------- PostgreSQL ----------------
//
// 与官方仓库的 schema.sql 一一对应：表名、列名、列类型完全一致。

func initSchema() error {
	stmts := []string{
		`SET TIME ZONE 'UTC'`,
		`CREATE EXTENSION IF NOT EXISTS pgcrypto`,
		`CREATE TABLE IF NOT EXISTS payments (
			id         VARCHAR(255) PRIMARY KEY NOT NULL,
			name       VARCHAR(255)             NOT NULL,
			cc_info    VARCHAR(255)             NOT NULL,
			created_at TIMESTAMP                NOT NULL
		)`,
	}
	for _, s := range stmts {
		if _, err := db.Exec(s); err != nil {
			return fmt.Errorf("init schema: %s -> %w", s, err)
		}
	}
	return nil
}

// ---------------- HTTP 路由 ----------------

func main() {
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		dsn = "postgres://postgres:postgres-admin-password@127.0.0.1:5432/payments?sslmode=disable"
	}
	var err error
	db, err = sql.Open("postgres", dsn)
	if err != nil {
		panic(err)
	}
	if err := db.Ping(); err != nil {
		panic(fmt.Errorf("cannot reach postgres at %s: %w", dsn, err))
	}
	if err := initSchema(); err != nil {
		panic(err)
	}

	r := gin.Default()

	r.GET("/payments", func(c *gin.Context) {
		rows, err := db.Query(`SELECT id, name, cc_info, created_at FROM payments`)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
			return
		}
		defer rows.Close()
		out := []Payment{}
		for rows.Next() {
			var p Payment
			if err := rows.Scan(&p.ID, &p.Name, &p.CCInfo, &p.CreatedAt); err != nil {
				c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
				return
			}
			plain, err := decryptCC(p.CCInfo)
			if err != nil {
				c.JSON(http.StatusBadGateway, gin.H{"error": err.Error()})
				return
			}
			p.CCInfo = plain
			out = append(out, p)
		}
		c.JSON(http.StatusOK, out)
	})

	r.POST("/payments", func(c *gin.Context) {
		var in struct {
			Name   string `json:"name"`
			CCInfo string `json:"cc_info"`
		}
		if err := c.ShouldBindJSON(&in); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
			return
		}
		if in.Name == "" || in.CCInfo == "" {
			c.JSON(http.StatusBadRequest, gin.H{"error": "name 与 cc_info 都必填"})
			return
		}
		ct, err := encryptCC(in.CCInfo)
		if err != nil {
			c.JSON(http.StatusBadGateway, gin.H{"error": err.Error()})
			return
		}
		id := uuid.NewString()
		now := time.Now().UTC()
		if _, err := db.Exec(
			`INSERT INTO payments(id, name, cc_info, created_at) VALUES ($1,$2,$3,$4)`,
			id, in.Name, ct, now,
		); err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
			return
		}
		// 与官方 Java 版本一致：POST 返回包含刚插入这一条记录的数组；
		// 注意 cc_info 字段返回的是『落库的密文』本身，没有再走一次解密——
		// 这是官方实现的行为，本节如实保留。
		c.JSON(http.StatusOK, []Payment{{
			ID: id, Name: in.Name, CCInfo: ct, CreatedAt: now,
		}})
	})

	// 本节自加的运维端点：把所有旧版本密文重新封装到当前最新版本
	r.POST("/admin/rewrap", func(c *gin.Context) {
		rows, err := db.Query(`SELECT id, cc_info FROM payments`)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
			return
		}
		type idCipher struct{ id, ct string }
		var all []idCipher
		for rows.Next() {
			var x idCipher
			if err := rows.Scan(&x.id, &x.ct); err != nil {
				rows.Close()
				c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
				return
			}
			all = append(all, x)
		}
		rows.Close()
		updated := 0
		for _, x := range all {
			nc, err := rewrapCC(x.ct)
			if err != nil {
				c.JSON(http.StatusBadGateway, gin.H{"error": err.Error(), "rewrapped_so_far": updated})
				return
			}
			if nc != x.ct {
				if _, err := db.Exec(`UPDATE payments SET cc_info=$1 WHERE id=$2`, nc, x.id); err != nil {
					c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error(), "rewrapped_so_far": updated})
					return
				}
				updated++
			}
		}
		c.JSON(http.StatusOK, gin.H{"rewrapped": updated, "total": len(all)})
	})

	addr := os.Getenv("APP_ADDR")
	if addr == "" {
		addr = ":8080"
	}
	if err := r.Run(addr); err != nil {
		panic(err)
	}
}

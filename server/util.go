package main

import (
	"crypto/rand"
	"encoding/hex"
)

// randHex 生成 n 字节随机数的十六进制串，用于任务 id 后缀。
func randHex(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "0000"
	}
	return hex.EncodeToString(b)
}

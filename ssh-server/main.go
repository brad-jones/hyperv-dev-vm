package main

import (
	"bufio"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/pem"
	"fmt"
	"io"
	"io/ioutil"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/gliderlabs/ssh"
)

func normalizePath(p string) string {
	homeDir, err := os.UserHomeDir()
	if err != nil {
		log.Fatalf("failed to get home dir: %s", err)
	}
	return filepath.Clean(strings.Replace(p, "~", homeDir, 1))
}

func main() {
	var port string
	if os.Getenv("SSH_PORT") != "" {
		port = os.Getenv("SSH_PORT")
	} else {
		port = "22"
	}

	var hostKeyPath string
	if os.Getenv("SSH_HOST_KEY_PATH") != "" {
		hostKeyPath = normalizePath(os.Getenv("SSH_HOST_KEY_PATH"))
	} else {
		hostKeyPath = normalizePath("~/.ssh/host_key")
	}

	var authorizedKeysPath string
	if os.Getenv("SSH_AUTHORIZED_KEYS_PATH") != "" {
		authorizedKeysPath = normalizePath(os.Getenv("SSH_AUTHORIZED_KEYS_PATH"))
	} else {
		authorizedKeysPath = normalizePath("~/.ssh/authorized_keys")
	}

	if _, err := os.Stat(hostKeyPath); os.IsNotExist(err) {
		log.Println("generating new host key as non exists")
		hostKey, err := rsa.GenerateKey(rand.Reader, 4096)
		if err != nil {
			log.Fatalf("failed to generate new host key: %s", err)
		}
		pemdata := pem.EncodeToMemory(
			&pem.Block{
				Type:  "RSA PRIVATE KEY",
				Bytes: x509.MarshalPKCS1PrivateKey(hostKey),
			},
		)
		if err := ioutil.WriteFile(hostKeyPath, pemdata, 0644); err != nil {
			log.Fatalf("failed to write new host key: %s", err)
		}
	}

	log.Println("ssh server listening 0.0.0.0:" + port)

	c := make(chan os.Signal, 2)
	signal.Notify(c, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-c
		fmt.Println("Interrupt received, stopping...")
		os.Exit(0)
	}()

	log.Fatal(ssh.ListenAndServe(":"+port,
		func(s ssh.Session) {
			log.Printf("executing command: %+v", s.Command())

			executable, err := exec.LookPath(s.Command()[0])
			if err != nil {
				msg := fmt.Sprintf("failed to find executable: %s\n", err)
				log.Print(msg)
				io.WriteString(s, msg)
				return
			}
			log.Printf("executable path: %+v", executable)

			args := strings.Join(s.Command(), " ")
			log.Printf("args: %+v", args)

			if err := StartProcessAsCurrentUser(executable, args, ""); err != nil {
				msg := fmt.Sprintf("failed to start process: %s\n", err)
				log.Print(msg)
				io.WriteString(s, msg)
			}
		},
		ssh.HostKeyFile(hostKeyPath),
		ssh.PublicKeyAuth(func(ctx ssh.Context, key ssh.PublicKey) bool {
			file, err := os.Open(authorizedKeysPath)
			if err != nil {
				if os.IsNotExist(err) {
					log.Printf("login attempt failed: " + authorizedKeysPath + " does not exist")
					return false
				}
				log.Fatalf("failed to open file: %s", err)
			}
			defer file.Close()

			fileScanner := bufio.NewScanner(file)
			fileScanner.Split(bufio.ScanLines)
			for fileScanner.Scan() {
				allowedKey, comment, _, _, err := ssh.ParseAuthorizedKey(fileScanner.Bytes())
				if err != nil {
					log.Printf("failed to parse authorized_key: %s", err)
					continue
				}
				if ssh.KeysEqual(key, allowedKey) {
					log.Printf("login attempt success for key: %s", comment)
					return true
				}
			}

			log.Printf("login attempt failed: no matching keys")
			return false
		}),
	))
}

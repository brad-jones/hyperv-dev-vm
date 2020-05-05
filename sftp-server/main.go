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
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"

	gliderssh "github.com/gliderlabs/ssh"
	"github.com/pkg/sftp"
	"golang.org/x/crypto/ssh"
)

func normalizePath(p string) string {
	homeDir, err := os.UserHomeDir()
	if err != nil {
		log.Fatalf("failed to get home dir: %s", err)
	}
	return filepath.Clean(strings.Replace(p, "~", homeDir, 1))
}

func main() {
	// Handle interrupts
	c := make(chan os.Signal, 2)
	signal.Notify(c, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-c
		fmt.Println("Interrupt received, stopping...")
		os.Exit(0)
	}()

	// Configure the port that this service will run on
	var port string
	if os.Getenv("SSH_PORT") != "" {
		port = os.Getenv("SSH_PORT")
	} else {
		port = "22"
	}

	// Configure the path to the host file file
	var hostKeyPath string
	if os.Getenv("SSH_HOST_KEY_PATH") != "" {
		hostKeyPath = normalizePath(os.Getenv("SSH_HOST_KEY_PATH"))
	} else {
		hostKeyPath = normalizePath("~/.ssh/host_key")
	}

	// Configure the path to the authorized_keys file
	var authorizedKeysPath string
	if os.Getenv("SSH_AUTHORIZED_KEYS_PATH") != "" {
		authorizedKeysPath = normalizePath(os.Getenv("SSH_AUTHORIZED_KEYS_PATH"))
	} else {
		authorizedKeysPath = normalizePath("~/.ssh/authorized_keys")
	}

	// Setup public key authentication
	config := &ssh.ServerConfig{
		PublicKeyCallback: func(conn ssh.ConnMetadata, key ssh.PublicKey) (*ssh.Permissions, error) {
			file, err := os.Open(authorizedKeysPath)
			if err != nil {
				if os.IsNotExist(err) {
					log.Printf("login attempt failed: " + authorizedKeysPath + " does not exist")
					return nil, fmt.Errorf("key rejected for %q", conn.User())
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
				if gliderssh.KeysEqual(key, allowedKey) {
					log.Printf("login attempt success for key: %s", comment)
					return nil, nil
				}
			}

			log.Printf("login attempt failed: no matching keys")
			return nil, fmt.Errorf("key rejected for %q", conn.User())
		},
	}

	// Generate the host key file if it does exist
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

	// Read in the host key file and add it to the config
	privateBytes, err := ioutil.ReadFile(hostKeyPath)
	if err != nil {
		log.Fatal("Failed to load private key", err)
	}
	private, err := ssh.ParsePrivateKey(privateBytes)
	if err != nil {
		log.Fatal("Failed to parse private key", err)
	}
	config.AddHostKey(private)

	// Start listening on our port
	listener, err := net.Listen("tcp", "0.0.0.0:"+port)
	if err != nil {
		log.Fatal("failed to listen for connection", err)
	}
	log.Printf("sftp server listening on %v\n", listener.Addr())

	for {
		// Wait for a new connection
		conn, err := listener.Accept()
		if err != nil {
			log.Fatal("failed to accept incoming connection", err)
		}

		// As soon as we have pass it on to a new goroutine and wait for the next connection
		go func(conn net.Conn) {
			// Handshake the client, performs auth, etc...
			_, chans, reqs, err := ssh.NewServerConn(conn, config)
			if err != nil {
				log.Fatal("failed to handshake", err)
			}
			log.Printf("new client connected")

			// The incoming Request channel must be serviced.
			go ssh.DiscardRequests(reqs)

			// Service the incoming Channel channel.
			for newChannel := range chans {
				// Channels have a type, depending on the application level
				// protocol intended. In the case of an SFTP session, this is "subsystem"
				// with a payload string of "<length=4>sftp"
				log.Printf("Incoming channel: %s\n", newChannel.ChannelType())
				if newChannel.ChannelType() != "session" {
					newChannel.Reject(ssh.UnknownChannelType, "unknown channel type")
					log.Printf("Unknown channel type: %s\n", newChannel.ChannelType())
					continue
				}
				channel, requests, err := newChannel.Accept()
				if err != nil {
					log.Fatal("could not accept channel.", err)
				}
				log.Printf("Channel accepted\n")

				// Sessions have out-of-band requests such as "shell",
				// "pty-req" and "env".  Here we handle only the
				// "subsystem" request.
				go func(in <-chan *ssh.Request) {
					for req := range in {
						log.Printf("Request: %v\n", req.Type)
						ok := false
						switch req.Type {
						case "subsystem":
							log.Printf("Subsystem: %s\n", req.Payload[4:])
							if string(req.Payload[4:]) == "sftp" {
								ok = true
							}
						}
						log.Printf(" - accepted: %v\n", ok)
						req.Reply(ok, nil)
					}
				}(requests)

				server, err := sftp.NewServer(
					channel,
					sftp.WithDebug(os.Stdout),
				)
				if err != nil {
					log.Fatal(err)
				}

				if err := server.Serve(); err == io.EOF {
					server.Close()
					log.Print("sftp client exited session.")
				} else if err != nil {
					log.Fatal("sftp server completed with error:", err)
				}
			}
		}(conn)
	}
}

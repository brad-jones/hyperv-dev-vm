package main

import (
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

	"golang.org/x/crypto/ssh"
)

// credit: <https://gist.github.com/codref/473351a24a3ef90162cf10857fac0ff3>

func normalizePath(p string) string {
	homeDir, err := os.UserHomeDir()
	if err != nil {
		log.Fatalf("failed to get home dir: %s", err)
	}
	return filepath.Clean(strings.Replace(p, "~", homeDir, 1))
}

func parseSSHKey(file string) ssh.AuthMethod {
	buffer, err := ioutil.ReadFile(file)
	if err != nil {
		log.Fatalln(fmt.Sprintf("Cannot read SSH public key file %s", file))
		return nil
	}
	key, err := ssh.ParsePrivateKey(buffer)
	if err != nil {
		log.Fatalln(fmt.Sprintf("Cannot parse SSH public key file %s", file))
		return nil
	}
	return ssh.PublicKeys(key)
}

func handleClient(client net.Conn, remote net.Conn) {
	defer client.Close()
	chDone := make(chan bool)

	// Start remote -> local data transfer
	go func() {
		_, err := io.Copy(client, remote)
		if err != nil {
			log.Println(fmt.Sprintf("error while copy remote->local: %s", err))
		}
		chDone <- true
	}()

	// Start local -> remote data transfer
	go func() {
		_, err := io.Copy(remote, client)
		if err != nil {
			log.Println(fmt.Sprintf("error while copy local->remote: %s", err))
		}
		chDone <- true
	}()

	<-chDone
}

func main() {
	// Listen for interrupt and die
	c := make(chan os.Signal, 2)
	signal.Notify(c, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-c
		fmt.Println("Interrupt received, stopping...")
		os.Exit(0)
	}()

	// Read in config from environment
	var remoteServer string
	if os.Getenv("REMOTE_SERVER") != "" {
		remoteServer = os.Getenv("REMOTE_SERVER")
	} else {
		remoteServer = "dev-server.hyper-v.local:22"
	}
	log.Printf("remoteServer: %s\n", remoteServer)

	var remoteServerUser string
	if os.Getenv("REMOTE_SERVER_USER") != "" {
		remoteServerUser = os.Getenv("REMOTE_SERVER_USER")
	} else {
		remoteServerUser = "packer"
	}
	log.Printf("remoteServerUser: %s\n", remoteServerUser)

	var remoteServerKey string
	if os.Getenv("REMOTE_SERVER_KEY") != "" {
		remoteServerKey = os.Getenv("REMOTE_SERVER_KEY")
	} else {
		remoteServerKey = "~/.ssh/id_rsa"
	}
	log.Printf("remoteServerKey: %s\n", remoteServerKey)

	var localEndpoint string
	if os.Getenv("LOCAL_ENDPOINT") != "" {
		localEndpoint = os.Getenv("LOCAL_ENDPOINT")
	} else {
		localEndpoint = "127.0.0.1:22"
	}
	log.Printf("localEndpoint: %s\n", localEndpoint)

	var remoteEndpoint string
	if os.Getenv("REMOTE_ENDPOINT") != "" {
		remoteEndpoint = os.Getenv("REMOTE_ENDPOINT")
	} else {
		remoteEndpoint = "127.0.0.1:2222"
	}
	log.Printf("remoteEndpoint: %s\n", remoteEndpoint)

	// Connect to remote server
	log.Println("Connecting to remote ssh server")
	conn, err := ssh.Dial("tcp", remoteServer, &ssh.ClientConfig{
		User: remoteServerUser,
		Auth: []ssh.AuthMethod{
			parseSSHKey(normalizePath(remoteServerKey)),
		},
		HostKeyCallback: ssh.InsecureIgnoreHostKey(),
	})
	if err != nil {
		log.Fatalln(fmt.Printf("Dial INTO remote server error: %s", err))
	}

	// Open the remote endpoint
	log.Println("Opening remote endpoint")
	listener, err := conn.Listen("tcp", remoteEndpoint)
	if err != nil {
		log.Fatalln(fmt.Printf("Listen open port ON remote server error: %s", err))
	}
	defer listener.Close()

	// Handle incoming connections on reverse forwarded tunnel
	for {
		// Open the local endpoint
		log.Println("Opening local endpoint")
		local, err := net.Dial("tcp", localEndpoint)
		if err != nil {
			log.Fatalln(fmt.Printf("Dial INTO local service error: %s", err))
		}

		// Wait for new connection
		log.Println("Waiting for new connection from remote endpoint")
		client, err := listener.Accept()
		if err != nil {
			log.Fatalln(err)
		}

		// Copy io from remote to local
		log.Println("transferring data")
		handleClient(client, local)
	}
}

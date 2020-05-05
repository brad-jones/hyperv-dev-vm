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
	log.Println("transferring data")

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
	// Handle interrupts
	c := make(chan os.Signal, 2)
	signal.Notify(c, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-c
		fmt.Println("Interrupt received, stopping...")
		os.Exit(0)
	}()

	// Configure the remote ssh server we will connect to
	var remoteServer string
	if os.Getenv("REMOTE_SERVER") != "" {
		remoteServer = os.Getenv("REMOTE_SERVER")
	} else {
		remoteServer = "dev-server.wslhv.local:22"
	}
	log.Printf("remoteServer: %s\n", remoteServer)

	// Configure the username used to authenticate with the remote server
	var remoteServerUser string
	if os.Getenv("REMOTE_SERVER_USER") != "" {
		remoteServerUser = os.Getenv("REMOTE_SERVER_USER")
	} else {
		remoteServerUser = "packer"
	}
	log.Printf("remoteServerUser: %s\n", remoteServerUser)

	// Configure the ssh key file path that will be used to authenticate with the remote server
	var remoteServerKey string
	if os.Getenv("REMOTE_SERVER_KEY") != "" {
		remoteServerKey = os.Getenv("REMOTE_SERVER_KEY")
	} else {
		remoteServerKey = "~/.ssh/id_rsa"
	}
	log.Printf("remoteServerKey: %s\n", remoteServerKey)

	// Configure the local endpoint that the remote server will have access to
	var localEndpoint string
	if os.Getenv("LOCAL_ENDPOINT") != "" {
		localEndpoint = os.Getenv("LOCAL_ENDPOINT")
	} else {
		localEndpoint = "127.0.0.1:2222"
	}
	log.Printf("localEndpoint: %s\n", localEndpoint)

	// Configure the remote endpoint that the remote server will be able to access the local endpoint on
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

	// Killing any previous tunnels on remote server
	// Sometimes old tunnels can hang (not sure why) but this will make sure
	// they die before we attempt to bring up a new tunnel that would otherwise
	// fail because the port is already in use.
	remoteEndpointPort := strings.Split(remoteEndpoint, ":")[1]
	session, err := conn.NewSession()
	if err != nil {
		log.Fatal("Failed to create session: ", err)
	}
	defer session.Close()
	out, err := session.CombinedOutput(fmt.Sprintf("sudo kill $(sudo lsof -t -i:%s)", remoteEndpointPort))
	if err != nil {
		if v, ok := err.(*ssh.ExitError); ok {
			msg := v.Msg()
			if msg != "" {
				fmt.Println(v.Error())
				log.Fatalln(v.Msg())
			}
		}
	}
	stdout := strings.TrimSpace(string(out))
	if stdout != "kill: not enough arguments" {
		fmt.Println("killed old tunnel on remote with pid:", stdout)
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
		go handleClient(client, local)
	}
}

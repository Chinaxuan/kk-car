package main

import (
	"bufio"
	"crypto/sha1"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// The audio endpoint is deliberately separate from LuCI. LuCI issues a
// short-lived, single-session ticket to an already authenticated admin.
// The modem is never dialled from this server; call control stays in rpcd.
const ticketPath = "/tmp/kk-car-voice-ticket.json"
const readyPath = "/tmp/kk-car-voice-ready"
const guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

type ticket struct {
	Token   string `json:"token"`
	Expires int64  `json:"expires"`
}

type gateway struct{ active atomic.Bool }

func (g *gateway) serve(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet || r.URL.Path != "/audio" {
		http.NotFound(w, r)
		return
	}
	if !g.active.CompareAndSwap(false, true) {
		http.Error(w, "another call has the audio device", http.StatusConflict)
		return
	}
	defer g.active.Store(false)
	if !sameOrigin(r) || !validTicket(r.URL.Query().Get("ticket")) || !ready() {
		log.Printf("audio denied: origin_ok=%t ready=%t", sameOrigin(r), ready())
		http.Error(w, "audio unavailable", http.StatusForbidden)
		return
	}
	key := r.Header.Get("Sec-WebSocket-Key")
	if r.Header.Get("Upgrade") != "websocket" || !strings.Contains(strings.ToLower(r.Header.Get("Connection")), "upgrade") || !validKey(key) {
		http.Error(w, "websocket required", http.StatusBadRequest)
		return
	}
	// Hijacking a TLS HTTP/1.1 connection keeps the existing browser TLS
	// session. The connection is LAN-only and never proxied onto WAN.
	conn, rw, err := w.(http.Hijacker).Hijack()
	if err != nil {
		return
	}
	defer conn.Close()
	sum := sha1.Sum([]byte(key + guid))
	fmt.Fprintf(rw, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n", base64.StdEncoding.EncodeToString(sum[:]))
	if rw.Flush() != nil {
		log.Print("audio handshake flush failed")
		return
	}
	log.Print("audio session opened")
	audio(conn, rw)
	log.Print("audio session closed")
}

func validKey(key string) bool {
	raw, err := base64.StdEncoding.DecodeString(key)
	return err == nil && len(raw) == 16
}
func sameOrigin(r *http.Request) bool {
	origin := r.Header.Get("Origin")
	// The LuCI management page can be reached via either private address.
	// localhost is allowed only through an SSH loopback tunnel for testing.
	switch origin {
	case "https://192.168.88.1", "https://10.8.250.1", "http://localhost:18880", "http://127.0.0.1:18880":
		return true
	}
	return false
}
func validTicket(s string) bool {
	if len(s) != 64 {
		return false
	}
	data, err := os.ReadFile(ticketPath)
	if err != nil || len(data) > 256 {
		return false
	}
	var t ticket
	if json.Unmarshal(data, &t) != nil || t.Expires < time.Now().Unix() || t.Expires > time.Now().Add(time.Minute).Unix() || len(t.Token) != 64 {
		return false
	}
	if subtle.ConstantTimeCompare([]byte(s), []byte(t.Token)) != 1 {
		return false
	}
	// The ticket is single use. A replay cannot seize the microphone session.
	return os.Remove(ticketPath) == nil
}
func ready() bool {
	if _, err := os.Stat(readyPath); err != nil {
		return false
	}
	if _, err := os.Stat("/proc/asound/Baiwang"); err != nil {
		return false
	}
	return true
}

func audio(conn net.Conn, rw *bufio.ReadWriter) {
	var writeMu sync.Mutex
	send := func(op byte, payload []byte) error {
		writeMu.Lock()
		defer writeMu.Unlock()
		_ = conn.SetWriteDeadline(time.Now().Add(4 * time.Second))
		head := []byte{0x80 | op, 0}
		n := len(payload)
		if n < 126 {
			head[1] = byte(n)
		} else {
			head[1] = 126
			head = append(head, byte(n>>8), byte(n))
		}
		if _, err := conn.Write(head); err != nil {
			return err
		}
		_, err := conn.Write(payload)
		return err
	}
	capture := exec.Command("/usr/bin/arecord", "-q", "-D", "hw:Baiwang,0", "-f", "S16_LE", "-r", "8000", "-c", "1", "--period-size=160", "--buffer-size=640", "-t", "raw")
	playback := exec.Command("/usr/bin/aplay", "-q", "-D", "hw:Baiwang,0", "-f", "S16_LE", "-r", "8000", "-c", "1", "--period-size=160", "--buffer-size=640", "-t", "raw")
	capture.Stderr = os.Stderr
	playback.Stderr = os.Stderr
	mic, err := capture.StdoutPipe()
	if err != nil {
		_ = send(8, nil)
		return
	}
	speaker, err := playback.StdinPipe()
	if err != nil {
		_ = send(8, nil)
		return
	}
	if err := playback.Start(); err != nil {
		log.Printf("playback start: %v", err)
		_ = send(8, nil)
		return
	}
	if err := capture.Start(); err != nil {
		log.Printf("capture start: %v", err)
		_ = speaker.Close()
		_ = playback.Process.Kill()
		_ = playback.Wait()
		_ = send(8, nil)
		return
	}
	// Keep the module's UAC output clock running even while the browser is
	// opening its microphone or briefly stops sending. MaVo's CoreAudio output
	// callback does the same: it supplies silence when its uplink queue is empty.
	uplink := make(chan []byte, 12)
	stopPlayback := make(chan struct{})
	playbackDone := make(chan struct{})
	go func() {
		defer close(playbackDone)
		pace := time.NewTicker(20 * time.Millisecond)
		defer pace.Stop()
		silence := make([]byte, 320)
		for {
			select {
			case <-stopPlayback:
				return
			case <-pace.C:
				frame := silence
				select {
				case frame = <-uplink:
				default:
				}
				if _, err := speaker.Write(frame); err != nil {
					log.Printf("playback write: %v", err)
					_ = conn.Close()
					return
				}
			}
		}
	}()
	captureDone := make(chan struct{})
	go func() {
		defer close(captureDone)
		frame := make([]byte, 320)
		for {
			if _, err := io.ReadFull(mic, frame); err != nil {
				log.Printf("capture read: %v", err)
				_ = conn.Close()
				return
			}
			if send(2, frame) != nil {
				log.Print("capture websocket send failed")
				return
			}
		}
	}()
	for {
		_ = conn.SetReadDeadline(time.Now().Add(15 * time.Second))
		op, payload, err := readFrame(rw.Reader)
		if err != nil {
			log.Printf("websocket read: %v", err)
			break
		}
		if op == 8 {
			log.Print("browser closed audio")
			break
		}
		if op == 9 {
			if send(10, payload) != nil {
				break
			}
			continue
		}
		if op != 2 || len(payload) == 0 || len(payload) > 4096 || len(payload)%2 != 0 {
			log.Printf("invalid audio frame: opcode=%d bytes=%d", op, len(payload))
			break
		}
		for len(payload) >= 320 {
			frame := append([]byte(nil), payload[:320]...)
			select {
			case uplink <- frame:
			default:
				// A delayed browser must not build up seconds of old speech.
				select {
				case <-uplink:
				default:
				}
				uplink <- frame
			}
			payload = payload[320:]
		}
	}
	_ = conn.Close()
	close(stopPlayback)
	_ = speaker.Close()
	_ = capture.Process.Kill()
	_ = playback.Process.Kill()
	_ = capture.Wait()
	_ = playback.Wait()
	<-captureDone
	<-playbackDone
}

func readFrame(r *bufio.Reader) (byte, []byte, error) {
	a, err := r.ReadByte()
	if err != nil {
		return 0, nil, err
	}
	b, err := r.ReadByte()
	if err != nil {
		return 0, nil, err
	}
	if a&0x80 == 0 || b&0x80 == 0 {
		return 0, nil, errors.New("fragmented or unmasked websocket frame")
	}
	n := int(b & 0x7f)
	if n == 126 {
		hi, e := r.ReadByte()
		if e != nil {
			return 0, nil, e
		}
		lo, e := r.ReadByte()
		if e != nil {
			return 0, nil, e
		}
		n = int(hi)<<8 | int(lo)
	}
	if n == 127 || n > 4096 {
		return 0, nil, errors.New("oversized audio frame")
	}
	key := make([]byte, 4)
	if _, err := io.ReadFull(r, key); err != nil {
		return 0, nil, err
	}
	payload := make([]byte, n)
	if _, err := io.ReadFull(r, payload); err != nil {
		return 0, nil, err
	}
	for i := range payload {
		payload[i] ^= key[i%4]
	}
	return a & 0x0f, payload, nil
}
func main() {
	g := &gateway{}
	mux := http.NewServeMux()
	mux.HandleFunc("/audio", g.serve)
	// A local SSH tunnel offers a secure browser context at http://localhost
	// for setup/diagnostics. Never expose its unencrypted listener on LAN.
	if os.Getenv("KK_CAR_VOICE_PLAIN_LOOPBACK") == "1" {
		log.Fatal(http.ListenAndServe("127.0.0.1:8444", mux))
	}
	addr := os.Getenv("KK_CAR_VOICE_ADDR")
	if addr == "" {
		addr = "192.168.88.1:8443"
	}
	cert := os.Getenv("KK_CAR_VOICE_CERT")
	key := os.Getenv("KK_CAR_VOICE_KEY")
	if cert == "" {
		cert = "/etc/kk-car/private/voice.crt"
	}
	if key == "" {
		key = "/etc/kk-car/private/voice.key"
	}
	log.Fatal(http.ListenAndServeTLS(addr, cert, key, mux))
}

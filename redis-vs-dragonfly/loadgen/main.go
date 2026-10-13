// Load generator for the Redis vs Dragonfly benchmark.
// Each iteration does SET key value EX ttl, then GET key. Rate ramps linearly
// from RATE_START by RATE_STEP every STEP_SECONDS until RATE_MAX; latency per
// op is exported as a Prometheus histogram on :9090/metrics.
//
// Talks RESP over plain sockets, one connection per worker: go-redis burned
// ~25 µs of client CPU per op and became the bottleneck before either DB did.
// Cluster mode is handled by partitioning keys per shard up front (CRC16 slot
// -> owner from CLUSTER SLOTS), so no MOVED ever happens. No failover: this is
// a benchmark client, not a driver.
package main

import (
	"bufio"
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"golang.org/x/time/rate"
)

var (
	opDur = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "bench_op_duration_seconds",
		Help:    "Round-trip latency per operation.",
		Buckets: prometheus.ExponentialBucketsRange(0.00005, 2, 30),
	}, []string{"db", "op"})
	ops = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "bench_ops_total",
		Help: "Operations by result.",
	}, []string{"db", "op", "status"})
	target = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Name: "bench_target_rps",
		Help: "Requested iterations per second (each iteration = 1 SET + 1 GET).",
	}, []string{"db"})
)

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
func envInt(k string, def int) int {
	n, err := strconv.Atoi(env(k, strconv.Itoa(def)))
	if err != nil {
		log.Fatalf("%s: %v", k, err)
	}
	return n
}

// ---- minimal RESP ----

type conn struct {
	c  net.Conn
	r  *bufio.Reader
	w  *bufio.Writer
	ln []byte
}

func dial(addr string) (*conn, error) {
	c, err := net.DialTimeout("tcp", addr, 5*time.Second)
	if err != nil {
		return nil, err
	}
	c.(*net.TCPConn).SetNoDelay(true)
	return &conn{c: c, r: bufio.NewReaderSize(c, 64<<10), w: bufio.NewWriterSize(c, 16<<10)}, nil
}

func (c *conn) write(args ...[]byte) error {
	fmt.Fprintf(c.w, "*%d\r\n", len(args))
	for _, a := range args {
		fmt.Fprintf(c.w, "$%d\r\n", len(a))
		c.w.Write(a)
		if _, err := c.w.WriteString("\r\n"); err != nil {
			return err
		}
	}
	return nil
}

func (c *conn) send(args ...[]byte) error {
	if err := c.write(args...); err != nil {
		return err
	}
	return c.w.Flush()
}

func (c *conn) line() ([]byte, error) {
	l, err := c.r.ReadSlice('\n')
	if err != nil {
		return nil, err
	}
	return l[:len(l)-2], nil
}

// reply reads one RESP value. Arrays are only needed for CLUSTER SLOTS.
func (c *conn) reply() (any, error) {
	l, err := c.line()
	if err != nil {
		return nil, err
	}
	switch l[0] {
	case '+':
		return string(l[1:]), nil
	case ':':
		return strconv.ParseInt(string(l[1:]), 10, 64)
	case '-':
		return nil, errors.New(string(l[1:]))
	case '$':
		n, _ := strconv.Atoi(string(l[1:]))
		if n < 0 {
			return nil, nil
		}
		buf := make([]byte, n+2)
		if _, err := io.ReadFull(c.r, buf); err != nil {
			return nil, err
		}
		return buf[:n], nil
	case '*':
		n, _ := strconv.Atoi(string(l[1:]))
		if n < 0 {
			return nil, nil
		}
		arr := make([]any, n)
		for i := range arr {
			if arr[i], err = c.reply(); err != nil {
				return nil, err
			}
		}
		return arr, nil
	}
	return nil, fmt.Errorf("bad reply %q", l)
}

// skip discards one reply without allocating: hot path for SET/GET results.
func (c *conn) skip() error {
	l, err := c.line()
	if err != nil {
		return err
	}
	switch l[0] {
	case '-':
		return errors.New(string(l[1:]))
	case '$':
		n, _ := strconv.Atoi(string(l[1:]))
		if n > 0 {
			_, err = c.r.Discard(n + 2)
		}
	}
	return err
}

// crc16 is the XMODEM variant Redis Cluster uses for key slots.
func crc16(b []byte) uint16 {
	var crc uint16
	for _, x := range b {
		crc ^= uint16(x) << 8
		for i := 0; i < 8; i++ {
			if crc&0x8000 != 0 {
				crc = crc<<1 ^ 0x1021
			} else {
				crc <<= 1
			}
		}
	}
	return crc
}

// slotOwners maps slot -> node index using CLUSTER SLOTS from the first node.
func slotOwners(addrs []string) ([]int, error) {
	if len(addrs) == 1 {
		return nil, nil
	}
	c, err := dial(addrs[0])
	if err != nil {
		return nil, err
	}
	defer c.c.Close()
	c.send([]byte("CLUSTER"), []byte("SLOTS"))
	v, err := c.reply()
	if err != nil {
		return nil, err
	}
	owners := make([]int, 16384)
	for _, r := range v.([]any) {
		rng := r.([]any)
		master := rng[2].([]any)
		host := string(master[0].([]byte))
		port := master[1].(int64)
		idx := -1
		for i, a := range addrs {
			h, p, _ := net.SplitHostPort(a)
			if h == host && p == strconv.FormatInt(port, 10) {
				idx = i
			}
		}
		if idx < 0 {
			return nil, fmt.Errorf("slot owner %s:%d not in ADDRS", host, port)
		}
		for s := rng[0].(int64); s <= rng[1].(int64); s++ {
			owners[s] = idx
		}
	}
	return owners, nil
}

func main() {
	db := env("DB", "redis")
	addrs := strings.Split(env("ADDRS", "localhost:6379"), ",")
	nkeys := envInt("KEYS", 100000)
	size := envInt("VALUE_SIZE", 512)
	ttl := []byte(strconv.Itoa(envInt("TTL_SECONDS", 20)))
	workers := envInt("WORKERS", 256)
	rateStart := envInt("RATE_START", 1000)
	rateStep := envInt("RATE_STEP", 1000)
	rateMax := envInt("RATE_MAX", 200000)
	step := time.Duration(envInt("STEP_SECONDS", 60)) * time.Second
	// PIPELINE = requests in flight per connection. 1 = one round trip per op.
	// Cross-VM round trips were capped near 35k/s in the test lab, so depth 16
	// is what lets a server actually saturate. Latency is the batch round trip,
	// recorded once per op in the batch.
	pipe := envInt("PIPELINE", 1)

	owners, err := slotOwners(addrs)
	if err != nil {
		log.Fatalf("cluster slots: %v", err)
	}
	// Keys partitioned by owning node; standalone = everything on node 0.
	keys := make([][][]byte, len(addrs))
	for i := 0; i < nkeys; i++ {
		k := []byte("key:" + strconv.Itoa(i))
		n := 0
		if owners != nil {
			n = owners[crc16(k)&16383]
		}
		keys[n] = append(keys[n], k)
	}
	value := make([]byte, size)
	rand.Read(value)
	lim := rate.NewLimiter(rate.Limit(rateStart), workers*pipe)
	target.WithLabelValues(db).Set(float64(rateStart))
	ctx := context.Background()

	go func() {
		http.Handle("/metrics", promhttp.Handler())
		log.Fatal(http.ListenAndServe(":9090", nil))
	}()
	go func() {
		for r := rateStart; r < rateMax; {
			time.Sleep(step)
			r += rateStep
			if r > rateMax {
				r = rateMax
			}
			lim.SetLimit(rate.Limit(r))
			target.WithLabelValues(db).Set(float64(r))
			log.Printf("rate -> %d it/s", r)
		}
	}()

	setOK, getOK := ops.WithLabelValues(db, "set", "ok"), ops.WithLabelValues(db, "get", "ok")
	setErr, getErr := ops.WithLabelValues(db, "set", "error"), ops.WithLabelValues(db, "get", "error")
	setH, getH := opDur.WithLabelValues(db, "set"), opDur.WithLabelValues(db, "get")
	SET, GET, EX := []byte("SET"), []byte("GET"), []byte("EX")

	for w := 0; w < workers; w++ {
		node := w % len(addrs)
		go func(w, node int) {
			var c *conn
			ks := keys[node]
			for i := w * pipe; ; i += workers * pipe {
				if err := lim.WaitN(ctx, pipe); err != nil {
					return
				}
				if c == nil {
					if c, err = dial(addrs[node]); err != nil {
						setErr.Inc()
						time.Sleep(100 * time.Millisecond)
						continue
					}
				}
				c.c.SetDeadline(time.Now().Add(2 * time.Second))
				// SET batch, then GET batch, each measured as one round trip.
				t := time.Now()
				var err error
				for j := 0; j < pipe && err == nil; j++ {
					err = c.write(SET, ks[(i+j)%len(ks)], value, EX, ttl)
				}
				if err == nil {
					err = c.w.Flush()
				}
				for j := 0; j < pipe && err == nil; j++ {
					err = c.skip()
				}
				d := time.Since(t).Seconds()
				for j := 0; j < pipe; j++ {
					setH.Observe(d)
				}
				if err != nil {
					setErr.Add(float64(pipe))
					c.c.Close()
					c = nil
					continue
				}
				setOK.Add(float64(pipe))
				t = time.Now()
				for j := 0; j < pipe && err == nil; j++ {
					err = c.write(GET, ks[(i+j)%len(ks)])
				}
				if err == nil {
					err = c.w.Flush()
				}
				for j := 0; j < pipe && err == nil; j++ {
					err = c.skip()
				}
				d = time.Since(t).Seconds()
				for j := 0; j < pipe; j++ {
					getH.Observe(d)
				}
				if err != nil {
					getErr.Add(float64(pipe))
					c.c.Close()
					c = nil
					continue
				}
				getOK.Add(float64(pipe))
			}
		}(w, node)
	}
	log.Printf("db=%s addrs=%v workers=%d pipeline=%d keys/node=%v rate %d..%d step %d/%s", db, addrs, workers, pipe, lens(keys), rateStart, rateMax, rateStep, step)
	select {}
}

func lens(k [][][]byte) []int {
	out := make([]int, len(k))
	for i := range k {
		out[i] = len(k[i])
	}
	return out
}


// S3 load generator for the MinIO vs RustFS benchmark. Its bench_* metrics are
// what monitoring/dashboard.py reads.
//
// Open loop: a scheduler hands out intended start times at the target rate,
// workers run one request each, and latency is measured from the intended
// start, not from the moment a worker got free. A stalling server therefore
// shows as latency. If the schedule falls more than MAX_LAG_SECONDS behind,
// the missed slots are counted as status="dropped" and the schedule resyncs,
// so "achieved" drops below "target" instead of latency growing without bound.
//
// The rate ramps from RATE_START by RATE_STEP every STEP_SECONDS up to
// RATE_MAX (floats: large objects run at a few per second). The ramp stops
// when two steps in a row achieve less than STOP_BELOW x target, or after
// HOLD_STEPS steps at RATE_MAX. Then the process logs DONE and idles (it is a
// Deployment; `kubectl rollout restart` starts a fresh ramp).
//
// OP=put     PUT over a key space of KEYS objects (overwrites once it wraps),
//
//	KEYS_PER_PREFIX keys per prefix (default 1000, 0 = one flat prefix)
//	MULTIPART_PART_SIZE > 0 uploads objects larger than one part as
//	a multipart upload, MULTIPART_CONCURRENCY parts at a time
//
// OP=get     GET random keys; PREFILL=true writes the key space first
// OP=mixed   GET_SHARE of the requests are GETs, the rest PUTs (needs PREFILL)
// OP=verify-write / verify-check
//
//	write KEYS objects of VERIFY_SIZES with content derived from
//	SEED, or read them back and compare SHA-256 against the
//	recomputed content. Exits 0 only if every object is intact.
//
// Client: aws-sdk-go-v2 (vendor neutral), SigV4 with signed payload,
// path-style, plain HTTP, no retries (an error is an error), one keep-alive
// connection per worker. Payload bytes come from a seeded ChaCha8 stream
// generated once (incompressible); each PUT sends a different window of it.
package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"log"
	"math"
	"math/rand/v2"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var (
	opDur = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "bench_op_duration_seconds",
		Help:    "Latency per operation, from its scheduled start to the last byte.",
		Buckets: prometheus.ExponentialBucketsRange(0.0005, 120, 36),
	}, []string{"db", "op"})
	ops = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "bench_ops_total",
		Help: "Operations by result (ok, error, dropped = schedule slot nobody could take).",
	}, []string{"db", "op", "status"})
	bytesTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "bench_bytes_total",
		Help: "Object bytes moved by successful operations.",
	}, []string{"db", "op"})
	target = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Name: "bench_target_rps",
		Help: "Requested operations per second.",
	}, []string{"db"})
	verified = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Name: "bench_verify_objects",
		Help: "Objects by verify result (ok, missing, corrupt).",
	}, []string{"db", "result"})
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
func envFloat(k string, def float64) float64 {
	f, err := strconv.ParseFloat(env(k, strconv.FormatFloat(def, 'f', -1, 64)), 64)
	if err != nil {
		log.Fatalf("%s: %v", k, err)
	}
	return f
}

// sched is the open-loop schedule: one intended start time per operation.
type sched struct {
	next   time.Time
	maxLag time.Duration
}

// take returns the intended start of the next operation at `rate` per second,
// and how many slots were skipped because the schedule was more than maxLag
// behind `now` (the caller counts those as dropped).
func (s *sched) take(now time.Time, rate float64) (time.Time, int) {
	if s.next.IsZero() {
		s.next = now
	}
	dropped := 0
	if lag := now.Sub(s.next); lag > s.maxLag {
		dropped = int(lag.Seconds() * rate)
		s.next = now
	}
	t := s.next
	s.next = t.Add(time.Duration(float64(time.Second) / rate))
	return t, dropped
}

// payload is n incompressible bytes, the same for the same seed in every
// process, so verify-check can recompute what verify-write sent.
func payload(seed uint64, n int) []byte {
	var k [32]byte
	binary.LittleEndian.PutUint64(k[:], seed)
	b := make([]byte, n)
	rand.NewChaCha8(k).Read(b)
	return b
}

// verifyBody is the content of verify object i: a window of the payload that
// depends on i, stamped with i so no two objects are equal.
func verifyBody(p []byte, i, size int) []byte {
	off := 0
	if len(p) > size {
		off = i * 7919 % (len(p) - size)
	}
	b := bytes.Clone(p[off : off+size])
	binary.BigEndian.PutUint64(b, uint64(i))
	return b
}

// intact reports whether r yields exactly the bytes of want (by SHA-256).
func intact(r io.Reader, want []byte) (bool, error) {
	h := sha256.New()
	if _, err := io.Copy(h, r); err != nil {
		return false, err
	}
	w := sha256.Sum256(want)
	return bytes.Equal(h.Sum(nil), w[:]), nil
}

// stepStats collects one ramp step for the log line.
type stepStats struct {
	sync.Mutex
	ok, errs, dropped int
	bytes             int64
	lat               []float64
}

func (s *stepStats) add(d float64, n int64, err error) {
	s.Lock()
	if err != nil {
		s.errs++
	} else {
		s.ok++
		s.bytes += n
		s.lat = append(s.lat, d)
	}
	s.Unlock()
}

func quantile(sorted []float64, q float64) float64 {
	if len(sorted) == 0 {
		return math.NaN()
	}
	return sorted[int(q*float64(len(sorted)-1))]
}

type client struct {
	s3       *s3.Client
	bucket   string
	partSize int // 0 = always one PUT
	partConc int
}

// partRanges splits size bytes into [offset, end) ranges of partSize; the last one is shorter.
func partRanges(size, partSize int) [][2]int {
	var r [][2]int
	for off := 0; off < size; off += partSize {
		r = append(r, [2]int{off, min(off+partSize, size)})
	}
	return r
}

// put uploads b as one object: a single PUT, or a multipart upload when it is
// larger than one part (what aws-cli, mc and the SDK transfer managers do).
func (c *client) put(ctx context.Context, key string, b []byte) error {
	if c.partSize <= 0 || len(b) <= c.partSize {
		return c.putOne(ctx, key, b)
	}
	up, err := c.s3.CreateMultipartUpload(ctx, &s3.CreateMultipartUploadInput{Bucket: &c.bucket, Key: &key})
	if err != nil {
		return err
	}
	ranges := partRanges(len(b), c.partSize)
	done := make([]types.CompletedPart, len(ranges))
	errs := make([]error, len(ranges))
	each(len(ranges), c.partConc, func(i int) {
		out, err := c.s3.UploadPart(ctx, &s3.UploadPartInput{Bucket: &c.bucket, Key: &key, UploadId: up.UploadId,
			PartNumber: aws.Int32(int32(i + 1)), Body: bytes.NewReader(b[ranges[i][0]:ranges[i][1]])})
		if errs[i] = err; err == nil {
			done[i] = types.CompletedPart{ETag: out.ETag, PartNumber: aws.Int32(int32(i + 1))}
		}
	})
	if err = errors.Join(errs...); err == nil {
		_, err = c.s3.CompleteMultipartUpload(ctx, &s3.CompleteMultipartUploadInput{Bucket: &c.bucket, Key: &key, UploadId: up.UploadId,
			MultipartUpload: &types.CompletedMultipartUpload{Parts: done}})
	}
	if err != nil { // do not leave parts behind; best effort, the original error is the one that counts
		c.s3.AbortMultipartUpload(context.WithoutCancel(ctx), &s3.AbortMultipartUploadInput{Bucket: &c.bucket, Key: &key, UploadId: up.UploadId})
	}
	return err
}

func (c *client) putOne(ctx context.Context, key string, b []byte) error {
	_, err := c.s3.PutObject(ctx, &s3.PutObjectInput{Bucket: &c.bucket, Key: &key, Body: bytes.NewReader(b), ContentLength: aws.Int64(int64(len(b)))})
	return err
}

// get streams the object into w and returns its length.
func (c *client) get(ctx context.Context, key string, w io.Writer) (int64, error) {
	out, err := c.s3.GetObject(ctx, &s3.GetObjectInput{Bucket: &c.bucket, Key: &key})
	if err != nil {
		return 0, err
	}
	defer out.Body.Close()
	return io.Copy(w, out.Body)
}

func (c *client) size(ctx context.Context, key string) int64 {
	out, err := c.s3.HeadObject(ctx, &s3.HeadObjectInput{Bucket: &c.bucket, Key: &key})
	if err != nil || out.ContentLength == nil {
		return -1
	}
	return *out.ContentLength
}

// each runs fn(i) for i in [0,n) on `workers` goroutines.
func each(n, workers int, fn func(i int)) {
	var next atomic.Int64
	var wg sync.WaitGroup
	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := int(next.Add(1)) - 1; i < n; i = int(next.Add(1)) - 1 {
				fn(i)
			}
		}()
	}
	wg.Wait()
}

func main() {
	db := env("DB", "minio")
	op := env("OP", "put")
	size := envInt("OBJECT_SIZE", 4096)
	nkeys := envInt("KEYS", 100000)
	workers := envInt("WORKERS", 64)
	rateStart, rateStep, rateMax := envFloat("RATE_START", 100), envFloat("RATE_STEP", 100), envFloat("RATE_MAX", 10000)
	step := time.Duration(envInt("STEP_SECONDS", 30)) * time.Second
	holdSteps := envInt("HOLD_STEPS", 1)
	stopBelow := envFloat("STOP_BELOW", 0.9)
	getShare := envFloat("GET_SHARE", 0.7)
	timeout := time.Duration(envInt("OP_TIMEOUT_SECONDS", 60)) * time.Second
	seed := uint64(envInt("SEED", 1))

	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.MaxIdleConns, tr.MaxIdleConnsPerHost, tr.DisableCompression = 0, workers, true
	c := &client{bucket: env("BUCKET", "bench"), partSize: envInt("MULTIPART_PART_SIZE", 0), partConc: envInt("MULTIPART_CONCURRENCY", 4), s3: s3.New(s3.Options{
		Region:       env("REGION", "us-east-1"),
		BaseEndpoint: aws.String(env("ENDPOINT", "http://localhost:9000")),
		UsePathStyle: true,
		Credentials:  credentials.NewStaticCredentialsProvider(os.Getenv("ACCESS_KEY"), os.Getenv("SECRET_KEY"), ""),
		HTTPClient:   &http.Client{Transport: tr},
		Retryer:      aws.NopRetryer{},
		// The SDK's newer default adds a CRC32 to every PUT and checks one on
		// every GET. Off: the SigV4 signed payload (SHA-256) already covers
		// PUTs, and warp does not send it either.
		RequestChecksumCalculation: aws.RequestChecksumCalculationWhenRequired,
		ResponseChecksumValidation: aws.ResponseChecksumValidationWhenRequired,
	})}
	bg := context.Background()

	go func() {
		http.Handle("/metrics", promhttp.Handler())
		log.Fatal(http.ListenAndServe(":9090", nil))
	}()

	// The server may still be starting: retry the bucket for two minutes.
	for deadline := time.Now().Add(2 * time.Minute); ; time.Sleep(2 * time.Second) {
		_, err := c.s3.CreateBucket(bg, &s3.CreateBucketInput{Bucket: &c.bucket})
		if err == nil || strings.Contains(err.Error(), "BucketAlready") {
			break
		}
		if time.Now().After(deadline) {
			log.Fatalf("create bucket: %v", err)
		}
		log.Printf("waiting for %s: %v", db, err)
	}

	if strings.HasPrefix(op, "verify-") {
		os.Exit(verify(c, db, op == "verify-write", nkeys, workers, seed, timeout))
	}

	// One buffer, a bit larger than an object, so every PUT sends a different window.
	slack := min(size, 1<<20)
	pl := payload(seed, size+slack)
	// KEYS_PER_PREFIX objects per "directory". One flat prefix is a different
	// test: with 200k objects in it, MinIO on ext4 fell from about 600 to about
	// 250 PUT/s at 4 KiB while warp (which spreads keys over prefixes) kept 600
	// on the same volume. 0 = flat, to measure exactly that.
	perPrefix := envInt("KEYS_PER_PREFIX", 1000)
	key := func(i int) string {
		if perPrefix <= 0 {
			return fmt.Sprintf("o%d/%08d", size, i)
		}
		return fmt.Sprintf("o%d/%05d/%08d", size, i/perPrefix, i)
	}

	if env("PREFILL", "false") == "true" {
		ctx, cancel := context.WithTimeout(bg, timeout)
		// ponytail: first and last key present = filled. A half-finished prefill
		// with exactly those two keys would fool it; wipe the bucket if in doubt.
		done := c.size(ctx, key(0)) == int64(size) && c.size(ctx, key(nkeys-1)) == int64(size)
		cancel()
		if done {
			log.Printf("prefill: %d objects of %d bytes already there", nkeys, size)
		} else {
			t0 := time.Now()
			var n, bad atomic.Int64
			each(nkeys, envInt("PREFILL_WORKERS", workers), func(i int) {
				ctx, cancel := context.WithTimeout(bg, timeout)
				defer cancel()
				off := i % (slack + 1)
				err := c.put(ctx, key(i), pl[off:off+size])
				for try := 0; err != nil && try < 3; try++ { // a million PUTs: one hiccup must not void the data set
					time.Sleep(time.Second)
					err = c.put(ctx, key(i), pl[off:off+size])
				}
				if err != nil {
					bad.Add(1)
					ops.WithLabelValues(db, "prefill", "error").Inc()
					return
				}
				ops.WithLabelValues(db, "prefill", "ok").Inc()
				if k := n.Add(1); k%10000 == 0 {
					log.Printf("prefill: %d/%d", k, nkeys)
				}
			})
			el := time.Since(t0).Seconds()
			log.Printf("PREFILL objects=%d errors=%d seconds=%.0f obj/s=%.0f", n.Load(), bad.Load(), el, float64(n.Load())/el)
			if bad.Load() > 0 {
				log.Fatalf("prefill failed for %d objects; a GET run over holes would lie", bad.Load())
			}
		}
	}

	var seq atomic.Int64
	st := &stepStats{}
	jobs := make(chan time.Time)
	for w := 0; w < workers; w++ {
		go func() {
			for t := range jobs {
				name := op
				if op == "mixed" {
					name = "put"
					if rand.Float64() < getShare {
						name = "get"
					}
				}
				ctx, cancel := context.WithTimeout(bg, timeout)
				var n int64
				var err error
				if name == "get" {
					if n, err = c.get(ctx, key(rand.IntN(nkeys)), io.Discard); err == nil && n != int64(size) {
						err = fmt.Errorf("short object: %d of %d bytes", n, size)
					}
				} else {
					off := rand.IntN(slack + 1)
					n, err = int64(size), c.put(ctx, key(int(seq.Add(1))%nkeys), pl[off:off+size])
				}
				cancel()
				d := time.Since(t).Seconds()
				opDur.WithLabelValues(db, name).Observe(d)
				st.add(d, n, err)
				if err != nil {
					ops.WithLabelValues(db, name, "error").Inc()
					if st.errs < 3 { // racy read, only limits log noise
						log.Printf("%s error: %v", name, err)
					}
					continue
				}
				ops.WithLabelValues(db, name, "ok").Inc()
				bytesTotal.WithLabelValues(db, name).Add(float64(n))
			}
		}()
	}

	dropName := op
	if op == "mixed" {
		dropName = "get"
	}
	droppedC := ops.WithLabelValues(db, dropName, "dropped")
	log.Printf("db=%s op=%s size=%d keys=%d workers=%d part=%d x%d rate %g..%g step %g/%s", db, op, size, nkeys, workers, c.partSize, c.partConc, rateStart, rateMax, rateStep, step)
	s := &sched{maxLag: time.Duration(envFloat("MAX_LAG_SECONDS", 2) * float64(time.Second))}
	rate, low, held, peak, peakTarget := rateStart, 0, 0, 0.0, 0.0
	target.WithLabelValues(db).Set(rate)
	stepStart := time.Now()
	stepEnd := stepStart.Add(step)
	for {
		now := time.Now()
		if !now.Before(stepEnd) {
			st.Lock()
			ok, errs, dropped, nbytes, lat := st.ok, st.errs, st.dropped, st.bytes, st.lat
			st.ok, st.errs, st.dropped, st.bytes, st.lat = 0, 0, 0, 0, nil
			st.Unlock()
			sort.Float64s(lat)
			el := now.Sub(stepStart).Seconds()
			got := float64(ok) / el
			log.Printf("STEP target=%g ok/s=%.1f MiB/s=%.1f errors=%d dropped=%d p50=%.1fms p99=%.1fms",
				rate, got, float64(nbytes)/el/(1<<20), errs, dropped, quantile(lat, 0.5)*1e3, quantile(lat, 0.99)*1e3)
			if got > peak {
				peak, peakTarget = got, rate
			}
			if got < stopBelow*rate {
				low++
			} else {
				low = 0
			}
			if rate >= rateMax {
				held++
			}
			if low >= 2 || held >= holdSteps {
				break
			}
			rate = min(rate+rateStep, rateMax)
			target.WithLabelValues(db).Set(rate)
			stepStart, stepEnd = now, now.Add(step)
		}
		t, dropped := s.take(now, rate)
		if d := t.Sub(now); d > 0 {
			time.Sleep(min(d, stepEnd.Sub(now)))
			if d > stepEnd.Sub(now) { // low rates: the next slot is in a later step
				s.next = t
				continue
			}
		}
		select {
		case jobs <- t:
		default: // every worker is busy: wait for one, but not past the step
			select {
			case jobs <- t:
			case <-time.After(time.Until(stepEnd)):
				dropped++
			}
		}
		if dropped > 0 {
			droppedC.Add(float64(dropped))
			st.Lock()
			st.dropped += dropped
			st.Unlock()
		}
	}
	target.WithLabelValues(db).Set(0)
	log.Printf("DONE db=%s op=%s size=%d peak ok/s=%.1f at target=%g", db, op, size, peak, peakTarget)
	select {}
}

// verify writes or checks nkeys objects and returns the process exit code.
func verify(c *client, db string, write bool, nkeys, workers int, seed uint64, timeout time.Duration) int {
	var sizes []int
	maxSize := 0
	for _, f := range strings.Split(env("VERIFY_SIZES", "4096,65536,1048576"), ",") {
		n, err := strconv.Atoi(f)
		if err != nil || n < 8 {
			log.Fatalf("VERIFY_SIZES: %q", f)
		}
		sizes = append(sizes, n)
		maxSize = max(maxSize, n)
	}
	pl := payload(seed, maxSize+1<<20)
	var ok, missing, corrupt, logged atomic.Int64
	bad := func(counter *atomic.Int64, key string, why any) {
		counter.Add(1)
		if logged.Add(1) <= 20 {
			log.Printf("BAD %s: %v", key, why)
		}
	}
	each(nkeys, workers, func(i int) {
		key := fmt.Sprintf("verify/%08d", i)
		want := verifyBody(pl, i, sizes[i%len(sizes)])
		ctx, cancel := context.WithTimeout(context.Background(), timeout)
		defer cancel()
		if write {
			if err := c.put(ctx, key, want); err != nil {
				bad(&missing, key, err)
				return
			}
			ok.Add(1)
			return
		}
		pr, pw := io.Pipe()
		go func() {
			_, err := c.get(ctx, key, pw)
			pw.CloseWithError(err)
		}()
		same, err := intact(pr, want)
		switch {
		case err != nil: // not found, or the read broke off: the object is not retrievable
			bad(&missing, key, err)
		case !same:
			bad(&corrupt, key, errors.New("SHA-256 mismatch"))
		default:
			ok.Add(1)
		}
	})
	mode := "check"
	if write {
		mode = "write"
	}
	for r, v := range map[string]*atomic.Int64{"ok": &ok, "missing": &missing, "corrupt": &corrupt} {
		verified.WithLabelValues(db, r).Set(float64(v.Load()))
	}
	log.Printf("VERIFY %s db=%s objects=%d ok=%d missing=%d corrupt=%d", mode, db, nkeys, ok.Load(), missing.Load(), corrupt.Load())
	if ok.Load() != int64(nkeys) {
		return 1
	}
	return 0
}

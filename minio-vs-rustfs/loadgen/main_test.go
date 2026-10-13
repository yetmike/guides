package main

import (
	"bytes"
	"testing"
	"time"
)

// The schedule is the part that makes the benchmark open loop; the verify
// helpers are what test 2 relies on to call an object lost or corrupt.
func TestSched(t *testing.T) {
	t0 := time.Unix(1000, 0)

	// Fractional rate: one op every 2 s, on the schedule, not on the clock.
	s := &sched{maxLag: 2 * time.Second}
	for i := 0; i < 4; i++ {
		got, dropped := s.take(t0.Add(time.Duration(i)*2*time.Second+time.Millisecond), 0.5)
		if want := t0.Add(time.Millisecond + time.Duration(i)*2*time.Second); !got.Equal(want) || dropped != 0 {
			t.Fatalf("rate 0.5, op %d: got %v dropped %d, want %v", i, got, dropped, want)
		}
	}

	// A client that keeps up gets exactly rate x seconds slots.
	s = &sched{maxLag: 2 * time.Second}
	n := 0
	for now := t0; ; n++ {
		slot, _ := s.take(now, 1000)
		if slot.Sub(t0) >= time.Second {
			break
		}
		now = slot
	}
	if n != 1000 {
		t.Fatalf("rate 1000 for 1 s: %d slots", n)
	}

	// A late caller within maxLag still gets the old intended time (latency
	// counts the wait); beyond maxLag the missed slots are dropped.
	s = &sched{maxLag: 2 * time.Second}
	s.take(t0, 100)
	if slot, dropped := s.take(t0.Add(time.Second), 100); !slot.Equal(t0.Add(10*time.Millisecond)) || dropped != 0 {
		t.Fatalf("1 s late: slot %v dropped %d", slot, dropped)
	}
	late := t0.Add(5*time.Second + 20*time.Millisecond)
	if slot, dropped := s.take(late, 100); !slot.Equal(late) || dropped != 500 {
		t.Fatalf("5 s late: slot %v dropped %d, want resync and 500", slot, dropped)
	}
}

func TestVerify(t *testing.T) {
	p := payload(1, 1<<16)
	if !bytes.Equal(p, payload(1, 1<<16)) || bytes.Equal(p, payload(2, 1<<16)) {
		t.Fatal("payload must depend on the seed and on nothing else")
	}
	a, b := verifyBody(p, 7, 4096), verifyBody(p, 8, 4096)
	if len(a) != 4096 || bytes.Equal(a, b) || !bytes.Equal(a, verifyBody(payload(1, 1<<16), 7, 4096)) {
		t.Fatal("verifyBody must be reproducible and differ per object")
	}
	if ok, err := intact(bytes.NewReader(a), a); !ok || err != nil {
		t.Fatal("identical bytes reported as corrupt")
	}
	flipped := bytes.Clone(a)
	flipped[2000] ^= 1
	for name, got := range map[string][]byte{"bit flip": flipped, "truncated": a[:4095], "other object": b, "empty": nil} {
		if ok, _ := intact(bytes.NewReader(got), a); ok {
			t.Fatalf("%s not detected", name)
		}
	}
}

func TestPartRanges(t *testing.T) {
	const mib = 1 << 20
	r := partRanges(100*mib, 16*mib)
	if len(r) != 7 || r[0] != [2]int{0, 16 * mib} || r[6] != [2]int{96 * mib, 100 * mib} {
		t.Fatalf("100 MiB in 16 MiB parts: %v", r)
	}
	covered := 0
	for i, p := range r {
		if i > 0 && p[0] != r[i-1][1] {
			t.Fatalf("gap or overlap before part %d: %v", i+1, r)
		}
		covered += p[1] - p[0]
	}
	if covered != 100*mib || len(partRanges(32*mib, 16*mib)) != 2 || len(partRanges(1, 16*mib)) != 1 {
		t.Fatalf("parts must cover the object exactly: %d", covered)
	}
}

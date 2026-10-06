package main

import (
	"bytes"
	"crypto/mlkem"
	"fmt"
)

// errors skipped to fit the screen
func main() {
	// Alice: make a key pair, share the public (encapsulation) key
	alice, _ := mlkem.GenerateKey768()
	pub := alice.EncapsulationKey().Bytes()

	// Bob: lock a fresh random secret with Alice's public key
	ek, _ := mlkem.NewEncapsulationKey768(pub)
	bobSecret, ciphertext := ek.Encapsulate()

	// Alice: unlock it with her private (decapsulation) key
	aliceSecret, _ := alice.Decapsulate(ciphertext)

	fmt.Println("public key:", len(pub), "bytes")
	fmt.Println("ciphertext:", len(ciphertext), "bytes")
	fmt.Printf("bob:   %x\n", bobSecret)
	fmt.Printf("alice: %x\n", aliceSecret)
	fmt.Println("same secret:", bytes.Equal(bobSecret, aliceSecret))
}

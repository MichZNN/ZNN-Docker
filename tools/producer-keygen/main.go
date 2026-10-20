// producer-keygen creates a new Zenon producer keystore and (optionally)
// writes the matching "Producer" block into the node's config.json.
//
// It uses the wallet package of go-zenon itself, so the keystore has exactly
// the format znnd expects (same format as znn-controller and Syrius).
//
// The Dockerfile copies this file into the go-zenon source tree at
// cmd/producer-keygen and builds it against the same go-zenon version as znnd.
package main

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/tyler-smith/go-bip39"

	"github.com/zenon-network/go-zenon/wallet"
)

func main() {
	home, _ := os.UserHomeDir()

	dataDir := flag.String("data", filepath.Join(home, ".znn"), "znnd data directory (contains config.json)")
	walletDir := flag.String("wallet", "", "wallet directory (default: <data>/wallet)")
	name := flag.String("name", "producer", "file name of the new keystore inside the wallet directory")
	passwordFile := flag.String("password-file", "", "read the keystore password from this file (default: generate a random one)")
	updateConfig := flag.Bool("update-config", true, "write the Producer block into <data>/config.json")
	force := flag.Bool("force", false, "replace an existing Producer block in config.json")
	flag.Parse()

	if *walletDir == "" {
		*walletDir = filepath.Join(*dataDir, "wallet")
	}
	keyPath := filepath.Join(*walletDir, *name)
	configPath := filepath.Join(*dataDir, "config.json")

	// Refuse to do anything destructive before generating keys.
	if _, err := os.Stat(keyPath); err == nil {
		fail("keystore already exists: %s (choose another -name)", keyPath)
	}
	var cfg map[string]any
	if *updateConfig {
		var err error
		cfg, err = readConfig(configPath)
		if err != nil {
			fail("cannot read %s: %v", configPath, err)
		}
		if p, ok := cfg["Producer"]; ok && p != nil && !*force {
			fail("%s already contains a Producer block; use -force to replace it", configPath)
		}
	}

	password, err := getPassword(*passwordFile)
	if err != nil {
		fail("password: %v", err)
	}

	// Generate keystore (BIP-39 entropy -> seed -> Zenon account index 0).
	entropy := wallet.GetEntropyCSPRNG(32)
	mnemonic, err := bip39.NewMnemonic(entropy)
	if err != nil {
		fail("mnemonic: %v", err)
	}
	ks := &wallet.KeyStore{
		Entropy:  entropy,
		Seed:     bip39.NewSeed(mnemonic, ""),
		Mnemonic: mnemonic,
	}
	_, kp, err := ks.DeriveForIndexPath(0)
	if err != nil {
		fail("derive address: %v", err)
	}
	ks.BaseAddress = kp.Address

	kf, err := ks.Encrypt(password)
	if err != nil {
		fail("encrypt keystore: %v", err)
	}
	if err := os.MkdirAll(*walletDir, 0o700); err != nil {
		fail("create wallet dir: %v", err)
	}
	kf.Path = keyPath
	if err := kf.Write(); err != nil {
		fail("write keystore: %v", err)
	}
	_ = os.Chmod(keyPath, 0o600)

	// Verify: read it back and decrypt it the same way znnd does.
	rk, err := wallet.ReadKeyFile(keyPath)
	if err != nil {
		fail("verify (read): %v", err)
	}
	dks, err := rk.Decrypt(password)
	if err != nil {
		fail("verify (decrypt): %v", err)
	}
	if dks.BaseAddress != kp.Address {
		fail("verify: address mismatch (%v != %v)", dks.BaseAddress, kp.Address)
	}

	fmt.Printf("Keystore created : %s\n", keyPath)
	fmt.Printf("Producer address : %s\n", kp.Address)

	if *updateConfig {
		if err := backupFile(configPath); err != nil {
			fail("backup config: %v", err)
		}
		cfg["Producer"] = map[string]any{
			"Address":     kp.Address.String(),
			"Index":       0,
			"KeyFilePath": *name,
			"Password":    password,
		}
		if err := writeConfig(configPath, cfg); err != nil {
			fail("write config: %v", err)
		}
		fmt.Printf("Config updated   : %s (Producer block written)\n", configPath)
	} else {
		fmt.Println("Config not changed (-update-config=false). Add this block yourself:")
		block, _ := json.MarshalIndent(map[string]any{"Producer": map[string]any{
			"Address": kp.Address.String(), "Index": 0, "KeyFilePath": *name, "Password": password,
		}}, "", "    ")
		fmt.Println(string(block))
	}

	fmt.Println()
	fmt.Println("Next steps:")
	fmt.Println("  1. Back up the keystore file AND config.json (the password lives there).")
	fmt.Println("  2. Restart the node.")
	fmt.Println("  3. Use the producer address above when registering/updating your Pillar in Syrius.")
}

func getPassword(file string) (string, error) {
	if file == "" {
		b := make([]byte, 24)
		if _, err := rand.Read(b); err != nil {
			return "", err
		}
		return base64.RawURLEncoding.EncodeToString(b), nil
	}
	b, err := os.ReadFile(file)
	if err != nil {
		return "", err
	}
	p := strings.TrimRight(string(b), "\r\n")
	if len(p) < 12 {
		return "", errors.New("password must be at least 12 characters")
	}
	return p, nil
}

func readConfig(path string) (map[string]any, error) {
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return map[string]any{}, nil
	}
	if err != nil {
		return nil, err
	}
	cfg := map[string]any{}
	if len(strings.TrimSpace(string(b))) == 0 {
		return cfg, nil
	}
	if err := json.Unmarshal(b, &cfg); err != nil {
		return nil, fmt.Errorf("invalid JSON: %w", err)
	}
	return cfg, nil
}

func writeConfig(path string, cfg map[string]any) error {
	b, err := json.MarshalIndent(cfg, "", "    ")
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, append(b, '\n'), 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func backupFile(path string) error {
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	bak := fmt.Sprintf("%s.bak-%s", path, time.Now().Format("20060102-150405"))
	return os.WriteFile(bak, b, 0o600)
}

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "error: "+format+"\n", args...)
	os.Exit(1)
}

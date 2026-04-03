package main

import (
	"fmt"
	"log"
	"os"
	"syscall"
	"unsafe"
)

// ptyWriter wraps a PTY master fd for non-blocking writes.
// Writes that fail with EAGAIN (buffer full) or EIO (no slave reader)
// are silently dropped so the simulator loop never stalls.
type ptyWriter struct {
	master    *os.File
	linkPath  string
	slavePath string
}

func (pw *ptyWriter) Write(p []byte) (int, error) {
	n, err := pw.master.Write(p)
	if err != nil {
		if isTransientPTYError(err) {
			return len(p), nil
		}
		return n, err
	}
	return n, nil
}

func (pw *ptyWriter) Close() error {
	os.Remove(pw.linkPath)
	return pw.master.Close()
}

func isTransientPTYError(err error) bool {
	if pe, ok := err.(*os.PathError); ok {
		err = pe.Err
	}
	return err == syscall.EAGAIN || err == syscall.EIO
}

// openPTYLink creates a PTY pair, symlinks the slave to linkPath, and
// returns a ptyWriter that writes to the master with O_NONBLOCK.
func openPTYLink(linkPath string) (*ptyWriter, error) {
	master, err := os.OpenFile("/dev/ptmx", os.O_RDWR|syscall.O_NONBLOCK|syscall.O_NOCTTY, 0)
	if err != nil {
		return nil, fmt.Errorf("open /dev/ptmx: %w", err)
	}

	fd := master.Fd()

	var ptyNum uint32
	if _, _, errno := syscall.Syscall(syscall.SYS_IOCTL, fd,
		syscall.TIOCGPTN, uintptr(unsafe.Pointer(&ptyNum))); errno != 0 {
		master.Close()
		return nil, fmt.Errorf("TIOCGPTN: %w", errno)
	}

	var unlock int32
	if _, _, errno := syscall.Syscall(syscall.SYS_IOCTL, fd,
		syscall.TIOCSPTLCK, uintptr(unsafe.Pointer(&unlock))); errno != 0 {
		master.Close()
		return nil, fmt.Errorf("TIOCSPTLCK: %w", errno)
	}

	slavePath := fmt.Sprintf("/dev/pts/%d", ptyNum)

	os.Remove(linkPath)
	if err := os.Symlink(slavePath, linkPath); err != nil {
		master.Close()
		return nil, fmt.Errorf("symlink %s -> %s: %w", linkPath, slavePath, err)
	}

	log.Printf("created PTY: %s -> %s", linkPath, slavePath)
	return &ptyWriter{master: master, linkPath: linkPath, slavePath: slavePath}, nil
}

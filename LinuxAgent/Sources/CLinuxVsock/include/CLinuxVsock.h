#ifndef CLINUXVSOCK_H
#define CLINUXVSOCK_H

// Re-exports <linux/vm_sockets.h>. Swift's Glibc overlay does
// not surface this header, so we bridge it through a C module
// that Swift can import directly.
//
// AF_VSOCK is the standard Linux VIRTIO-socket address family
// used to talk between a VM and its hypervisor. A listening
// process inside the guest binds with family = AF_VSOCK,
// cid = VMADDR_CID_ANY, and a 32-bit port number — exactly
// mirroring the macOS-side `VZVirtioSocketDevice.connect(toPort:)`
// on the host.
//
// Headers documented at
// https://man7.org/linux/man-pages/man7/vsock.7.html

#include <sys/socket.h>
#include <linux/vm_sockets.h>

#endif

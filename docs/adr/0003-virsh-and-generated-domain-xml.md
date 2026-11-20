# 0003. `virsh` plus generated domain XML

Status: accepted, 2026-11-20; revised 2026-11-21

## Context

v0 builds a `virt-install` command line. That is a string interface, needs a
heavy extra package on the host, and can only be tested by comparing
arguments.

A libvirt URI is more than an address: some transports accept a parameter that
names a program to run.

## Decision

- vmseed generates the libvirt domain XML itself, from a typed specification,
  as an element tree.
- It talks to libvirt only through the `virsh` command, addressing a domain by
  the UUID vmseed generated.
- **Only local `qemu` connections are accepted**: the session or system
  daemon, optionally through an explicit Unix socket path. Remote transports
  and any other URI parameter are refused.
- libvirt is never asked to delete a file: `undefine` keeps the NVRAM, and
  vmseed removes it by name.
- One thin `Hypervisor` protocol exists so tests can use a fake. The
  hypervisor is not an extension point in v1.

## Consequences

- The package has no native dependency to compile at install time.
- The XML is a reviewable artifact: snapshot-tested and validated against
  libvirt's schema.
- `virt-install` is no longer needed on the host.
- vmseed owns the XML for firmware, Secure Boot, networking and shares, and
  must keep it correct across libvirt versions.
- A configuration value cannot make vmseed run a program through the URI.
- Remote hypervisors are out of scope.

## Alternatives

- **`virt-install`.** Fastest port and it resolves defaults, but keeps the
  string interface and the dependency.
- **`libvirt-python`.** Typed errors, but a C extension without wheels: it
  compiles against libvirt headers at install time or depends on a distro
  package.
- **QEMU directly.** Fewer dependencies, but vmseed would reimplement process
  supervision, firmware selection and Secure Boot.
- **Any libvirt URI.** More flexible, but a fleet file could then execute a
  command on the host.

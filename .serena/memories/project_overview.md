# Free5GC Project Overview

## Purpose
Free5GC is an open-source implementation of a 5th generation (5G) mobile core network (5GC) defined in 3GPP Release 15 (R15) and beyond. It's a Linux Foundation project that provides a complete 5G core network implementation for research, development, and testing purposes.

## Core Architecture
Free5GC implements the complete 5G Service-Based Architecture (SBA) with the following Network Functions (NFs):

### Control Plane Functions
- **AMF** (Access and Mobility Management Function): Handles mobility management and access authentication
- **AUSF** (Authentication Server Function): Manages authentication services  
- **NRF** (Network Repository Function): Service discovery and registration
- **NSSF** (Network Slice Selection Function): Network slice selection
- **PCF** (Policy Control Function): Policy control and charging rules
- **SMF** (Session Management Function): Session management and control
- **UDM** (Unified Data Management): User data management
- **UDR** (Unified Data Repository): Unified data repository
- **CHF** (Charging Function): Charging function with CDR generation
- **NEF** (Network Exposure Function): Network exposure for third-party services

### User Plane Functions
- **UPF** (User Plane Function): User plane packet processing and forwarding

### Non-3GPP Access Functions
- **N3IWF** (Non-3GPP Interworking Function): WiFi interworking function
- **TNGF** (Trusted Non-3GPP Gateway Function): Trusted non-3GPP gateway function

## Key Technologies
- **Primary Language**: Go (all network functions)
- **Configuration**: YAML files
- **Communication Protocols**: 
  - HTTP/2 for Service-Based Interface (SBI) communication
  - PFCP (Packet Forwarding Control Protocol) for UPF communication
  - NGAP (Next Generation Application Protocol) for AMF-RAN interface
  - SCTP (Stream Control Transmission Protocol) for reliability
- **Web Management**: React-based webconsole
- **Testing**: Go testing framework with integration tests
- **Security**: TLS certificates, OAuth2 authentication between services

## Project Structure
```
├── NFs/           # Individual network function implementations
│   ├── amf/       # Access and Mobility Management Function
│   ├── ausf/      # Authentication Server Function
│   ├── nrf/       # Network Repository Function
│   ├── ...        # Other network functions
├── config/        # Configuration files for all network functions
├── webconsole/    # Web management interface (React frontend + Go backend)
├── test/          # Integration tests and utilities
├── bin/           # Compiled binaries (created after build)
├── cert/          # TLS certificates for secure communication
└── Makefile       # Build configuration
```

## Development Environment
- **Go Version**: 1.21 (using Go workspace mode)
- **Build System**: Make-based build system
- **Linting**: golangci-lint with comprehensive configuration
- **License**: Apache 2.0
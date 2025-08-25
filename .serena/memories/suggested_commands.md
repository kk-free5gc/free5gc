# Essential Commands for Free5GC Development

## Build Commands

### Core Build Commands
```bash
make nfs           # Build all network functions (default target)
make all           # Build all network functions and webconsole
make debug         # Build with debug symbols (-N -l flags)
make clean         # Clean built binaries
```

### Individual Network Function Builds
```bash
make amf           # Build AMF (Access and Mobility Management Function)
make ausf          # Build AUSF (Authentication Server Function)
make nrf           # Build NRF (Network Repository Function)
make nssf          # Build NSSF (Network Slice Selection Function)
make pcf           # Build PCF (Policy Control Function)
make smf           # Build SMF (Session Management Function)
make udm           # Build UDM (Unified Data Management)
make udr           # Build UDR (Unified Data Repository)
make n3iwf         # Build N3IWF (Non-3GPP Interworking Function)
make upf           # Build UPF (User Plane Function)
make chf           # Build CHF (Charging Function)
make tngf          # Build TNGF (Trusted Non-3GPP Gateway Function)
make nef           # Build NEF (Network Exposure Function)
make webconsole    # Build webconsole (requires Node.js/Yarn)
```

## Testing Commands

### Integration Tests
```bash
./test.sh                    # Run integration tests menu
./test.sh All               # Run all available tests
./test.sh TestRegistration  # Run specific registration test
./test_ci.sh               # Run CI tests
./test_ulcl.sh             # Run ULCL (Uplink Classifier) tests
./test_multiUPF.sh         # Run multi-UPF tests
```

### Test Options
```bash
./test.sh -o TestRegistration  # Run with packet capture (tcpdump)
```

## Code Quality Commands

### Linting and Formatting
```bash
golangci-lint run          # Run linter (uses .golangci.yml config)
golangci-lint run --fix    # Run linter with auto-fix
gofmt -s -w .              # Format Go code
```

Note: The project uses a comprehensive golangci-lint configuration with multiple enabled linters including gofmt, govet, errcheck, staticcheck, and others.

## Running the System

### Network Function Dependencies (Start Order)
1. **NRF** - Must be started first (service discovery)
2. **UDR** - Required before UDM/AUSF (data storage)
3. **UDM** - Required before AMF/SMF (subscriber data)
4. **AMF** - Core control plane function
5. **SMF** - Session management, depends on UPF for user plane
6. **UPF** - User plane function, can be deployed separately

### Example Startup
```bash
# Build all components first
make all

# Start network functions in dependency order
./bin/nrf -c ./config/nrfcfg.yaml &
./bin/udr -c ./config/udrcfg.yaml &
./bin/udm -c ./config/udmcfg.yaml &
./bin/amf -c ./config/amfcfg.yaml &
./bin/smf -c ./config/smfcfg.yaml &
./bin/upf -c ./config/upfcfg.yaml &
# ... other NFs as needed
```

## Development Workflow Commands

### Git and Version Control
```bash
git submodule update --init --recursive  # Initialize submodules
git status                               # Check working tree status
git describe --tags                      # Get version tag
```

### Workspace Management (Important for Module Builds)
```bash
# For individual NF compilation (avoids workspace version conflicts)
GOWORK=off make amf
# OR temporarily disable workspace
mv go.work go.work.bak
make amf
mv go.work.bak go.work
```

### Configuration Management
```bash
# Configuration files are in config/ directory
ls config/                              # List all configuration files
# Each NF has its own YAML configuration file following pattern: <nf>cfg.yaml
```

## Utility Commands

### System Commands (Linux-specific)
```bash
sudo ip netns list                      # List network namespaces (for testing)
sudo killall <process_name>             # Kill processes by name
./force_kill.sh                        # Force kill all free5gc processes
./reload_host_config.sh                # Reload host configuration
```

### Project Maintenance
```bash
find . -name "*.go" -not -path "*/vendor/*" | wc -l  # Count Go source files
find NFs/ -name "go.mod"                             # List all Go modules
```

## Debugging Commands

### Debug Builds
```bash
make debug          # Build with debug symbols for debugging
```

### Log Analysis
```bash
# NF logs are typically written to stdout/stderr
# Use standard tools for log analysis:
grep "ERROR" logfile.log
tail -f logfile.log
```

## Documentation and Help
```bash
# Project documentation is available at:
# - Official site: https://free5gc.org/
# - Guide: https://free5gc.org/guide/
# - Forum: https://forum.free5gc.org
```
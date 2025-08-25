# Code Style and Conventions for Free5GC

## Go Coding Standards

### General Go Conventions
The project follows standard Go conventions as outlined in the official Go documentation:
- Use `gofmt` for consistent formatting (enabled in .golangci.yml)
- Follow Go naming conventions (PascalCase for exported, camelCase for unexported)
- Use meaningful variable and function names
- Keep functions reasonably short (funlen: 60 lines, 40 statements per .golangci.yml)

### Import Organization
```go
// Standard library imports first
import (
    "context"
    "fmt"
    "time"
)

// Third-party imports
import (
    "github.com/gin-gonic/gin"
    "github.com/sirupsen/logrus"
)

// Local imports with free5gc prefix
import (
    "github.com/free5gc/amf/internal/context"
    "github.com/free5gc/openapi/models"
)
```

### Linting Configuration
The project uses comprehensive linting via `.golangci.yml`:

**Enabled Linters:**
- `gofmt` - Code formatting
- `govet` - Go vet checks
- `errcheck` - Error checking
- `staticcheck` - Static analysis
- `unused` - Unused code detection
- `gosimple` - Code simplification suggestions
- `ineffassign` - Ineffectual assignments
- `deadcode` - Dead code detection
- `lll` - Line length (max 120 characters)
- `godox` - TODO/FIXME/BUG comments detection
- `nakedret` - Naked returns check

**Code Complexity Limits:**
- Maximum line length: 120 characters
- Function length: 60 lines, 40 statements
- Cognitive complexity: 10
- Cyclomatic complexity: 10
- Minimum if statement complexity: 4

## Project-Specific Conventions

### Network Function Structure
Each NF follows a consistent directory structure:
```
NFs/<nf_name>/
├── cmd/           # Main application entry point
├── internal/      # Private application code
│   ├── context/   # Context and state management
│   ├── sbi/       # Service-Based Interface handlers
│   │   ├── api/   # HTTP API handlers
│   │   └── processor/ # Business logic processors
│   └── logger/    # Logging configuration
├── pkg/           # Public library code
├── go.mod         # Go module definition
└── go.sum         # Go module checksums
```

### Configuration Conventions
- All configuration files use YAML format
- Configuration files follow naming pattern: `<nf>cfg.yaml`
- Default IP addresses use 127.0.0.x range for local deployment
- Configuration structures are defined in each NF's internal/config package

### Logging Conventions
- Use structured logging via logrus
- Each NF has its own logger configuration
- Log levels: Debug, Info, Warning, Error, Fatal
- Include context information in log messages

### Error Handling
- Always check errors (enforced by errcheck linter)
- Use meaningful error messages
- Wrap errors with context when propagating: `fmt.Errorf("operation failed: %w", err)`
- Prefer returning errors over panicking

### API Design Conventions
- Follow 3GPP specifications for Service-Based Interface (SBI) design
- Use HTTP/2 for all SBI communications
- Implement OAuth2 authentication between services
- Use OpenAPI specifications for API documentation
- Follow RESTful principles for HTTP endpoints

### Testing Conventions
- Test files excluded from linting (tests: false in .golangci.yml)
- Integration tests use network namespaces for isolation
- Test utilities should be placed in test/ directory
- Use standard Go testing framework with testify for assertions

### Comments and Documentation
- Document exported functions, types, and packages
- Use Go doc conventions for documentation comments
- TODO/FIXME comments are flagged by linter (must be resolved)
- BUG comments indicate critical issues that need attention

### Naming Conventions
- Use consistent naming for similar concepts across NFs
- Context structures: `<NF>Context` (e.g., `AmfContext`)
- Configuration structures: `<NF>Config` (e.g., `AmfConfig`)
- HTTP handlers: `HTTP<Operation>` (e.g., `HTTPCreateUEContext`)
- Business logic: `<Operation>Procedure` (e.g., `RegistrationProcedure`)

### File Organization
- Keep related functionality in the same package
- Separate API handlers from business logic
- Use internal/ for private implementation details
- Use pkg/ for reusable library code

### Build Tags and Conditional Compilation
- Use build tags sparingly and document their purpose
- Prefer runtime configuration over compile-time conditionals
- Test builds should not include production code paths

### Version and Dependencies
- Use Go 1.21 as the target version
- Manage dependencies via Go modules (go.mod/go.sum)
- Use Go workspace mode for multi-module development
- Pin dependency versions for reproducible builds

### Performance Considerations
- Follow performance-oriented linting rules (gocritic performance tags enabled)
- Use efficient data structures and algorithms
- Profile code when performance is critical
- Consider memory allocation patterns in hot paths
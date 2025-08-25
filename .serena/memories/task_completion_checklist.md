# Task Completion Checklist for Free5GC

## Code Quality Verification

### 1. Linting and Formatting
- [ ] **Run golangci-lint**: `golangci-lint run`
  - Must pass all enabled linters (gofmt, govet, errcheck, staticcheck, etc.)
  - Check for TODO/FIXME/BUG comments that need resolution
  - Verify line length limits (120 characters max)
  - Ensure function complexity limits are met

- [ ] **Format code**: `gofmt -s -w .`
  - Apply consistent Go formatting
  - Use simplified syntax where possible

### 2. Build Verification
- [ ] **Individual NF builds**: `make <nf_name>`
  - Build specific network function you modified
  - Verify no compilation errors or warnings

- [ ] **Full system build**: `make all`
  - Ensure all network functions and webconsole build successfully
  - Verify Go workspace compatibility

- [ ] **Debug build**: `make debug` (if debugging symbols needed)
  - Confirm debug builds work for testing/debugging

### 3. Testing Requirements

#### Unit Tests (if applicable)
- [ ] **Run unit tests**: `go test ./...` (in specific NF directory)
  - Ensure existing tests pass
  - Add tests for new functionality

#### Integration Tests
- [ ] **Basic integration test**: `./test.sh TestRegistration`
  - Verify core functionality works end-to-end
  - Check UE registration and basic procedures

- [ ] **Relevant specific tests**: Choose appropriate tests based on changes:
  - `./test.sh TestServiceRequest` - for session-related changes
  - `./test.sh TestPDUSessionReleaseRequest` - for PDU session changes
  - `./test.sh TestDeregistration` - for mobility changes
  - `./test.sh TestNon3GPP` - for N3IWF/non-3GPP changes
  - `./test.sh TestMultiAmfRegistration` - for multi-AMF scenarios

#### CI Tests (for significant changes)
- [ ] **Run CI test suite**: `./test_ci.sh`
  - Execute comprehensive test suite
  - Required for major modifications

### 4. Configuration Validation
- [ ] **Configuration syntax**: Verify YAML configurations are valid
  - Check syntax with `yamllint` if available
  - Ensure configuration follows project conventions

- [ ] **Configuration compatibility**: 
  - Verify new configuration options have defaults
  - Ensure backward compatibility with existing configs

### 5. Documentation and Comments
- [ ] **Code documentation**: 
  - Document exported functions and types
  - Update inline comments for complex logic
  - Follow Go doc conventions

- [ ] **Update CLAUDE.md**: If adding new features or commands
  - Document new build targets
  - Add new testing procedures
  - Update architectural information

### 6. Version Control Preparation
- [ ] **Git status check**: `git status`
  - Review all modified files
  - Ensure no unintended changes

- [ ] **Commit message**: Follow conventional commit format
  - Use descriptive, concise commit messages
  - Reference issue numbers if applicable

### 7. Workspace Considerations
- [ ] **Go workspace compatibility**: 
  - Verify changes work with Go workspace mode enabled
  - Test individual module builds with `GOWORK=off make <nf>`
  - Ensure no cross-module dependency conflicts

### 8. Performance and Security
- [ ] **Security review**:
  - Ensure no secrets or credentials in code
  - Verify TLS/security configurations
  - Check for potential security vulnerabilities

- [ ] **Performance considerations**:
  - Review for obvious performance issues
  - Consider impact on system resources
  - Check for memory leaks in long-running processes

## Pre-Submission Checklist

### For Bug Fixes
- [ ] Root cause identified and addressed
- [ ] Fix verified with appropriate test case
- [ ] No regression in existing functionality
- [ ] Documentation updated if needed

### For New Features
- [ ] Feature implemented according to 3GPP specifications
- [ ] Integration points with other NFs considered
- [ ] Configuration options added if needed
- [ ] Tests cover new functionality
- [ ] Documentation includes new feature

### For Refactoring
- [ ] Functionality preserved (verified by tests)
- [ ] Code quality improved (linting passes)
- [ ] Performance not degraded
- [ ] API compatibility maintained

## Post-Completion Verification

### System Integration
- [ ] **Multi-NF startup**: Verify affected NFs start correctly in proper order
- [ ] **Service discovery**: Ensure NRF registration works
- [ ] **Inter-NF communication**: Verify SBI calls work between affected NFs

### Clean-up
- [ ] **Remove temporary files**: Clean any debugging artifacts
- [ ] **Remove dead code**: Clean unused imports, functions, variables
- [ ] **Update dependencies**: Ensure go.mod/go.sum are current

This checklist ensures that all changes maintain the high quality standards expected in the Free5GC project and follow 3GPP compliance requirements.
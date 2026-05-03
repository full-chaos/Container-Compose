# Container-Compose Review

## Executive Summary

Container-Compose is a well-architected Docker Compose-compatible tool for Apple Container that successfully bridges Compose workflows with Apple's native container management ecosystem. The codebase demonstrates strong separation of concerns and thoughtful abstractions, but has several areas for improvement in consistency, testing coverage, and modeling completeness.

## Detailed Analysis

### 1. Design Consistency Issues

#### a) Project Name Resolution Inconsistency
- **Location**: `Sources/Container-Compose/Commands/ComposeUp.swift` vs `ComposeDown.swift`
- **Issue**: As noted in commit 1f0451f, there was inconsistency in how container names were resolved between up and down commands
- **Fix Applied**: Extracted `effectiveContainerName` helper to resolve the inconsistency
- **Recommendation**: Audit all command implementations for similar inconsistencies in project/container naming logic

#### b) Runtime Abstraction Leaks
- **Location**: `Sources/Container-Compose/Runtime/AppleContainerizationRuntime.swift` and `BridgeContainerClientRuntime.swift`
- **Issue**: Multiple abstraction leaks documented in docs/plans/runtime-abstraction-leaks.md
  - Network CRUD operations return `.notSupported` in both conformers
  - Secrets management completely missing from native implementation
  - Volume management still relies on apple/container's XPC interface rather than containerization
- **Recommendation**: Create a prioritized roadmap to close these leaks, starting with secrets management using macOS Keychain as suggested in leak #11.

#### c) Inconsistent Error Handling
- **Location**: Multiple runtime implementations
- **Issue**: Different error handling patterns across conformers:
  - BridgeContainerClientRuntime sometimes wraps all errors as backendFailure (leak #12)
  - AppleContainerizationRuntime uses specific error types for some operations
- **Recommendation**: Establish a unified error handling protocol that maps upstream errors consistently to RuntimeError types.

### 2. Refactoring Opportunities

#### a) Compose Parsing and Validation
- **Location**: `Sources/Container-Compose/Codable Structs/DockerCompose.swift`
- **Opportunity**: The compose file parsing could be improved by:
  - Adding validation for required field combinations
  - Implementing schema version-specific parsing rules
  - Providing more detailed error messages for invalid compose files

**Example improvement**:
```swift
// Add validation method to DockerCompose
func validate() throws {
    guard !services.isEmpty else {
        throw ComposeValidationError.noServicesDefined
    }
    
    for (name, service) in services {
        guard let _ = service?.image ?? service?.build else {
            throw ComposeValidationError.serviceNeedsImageOrBuild(name)
        }
        
        // Validate port formats
        if let ports = service?.ports {
            try validatePorts(ports, forService: name)
        }
        
        // Validate resource constraints
        if let deploy = service?.deploy {
            try validateResources(deploy.resources, forService: name)
        }
    }
}
```

#### b) Volume Mount Handling
- **Location**: `Sources/Container-Compose/Commands/ComposeUp.swift` → `configVolume`
- **Opportunity**: The volume mount logic is deeply nested and complex
- **Recommendation**: Extract into a dedicated `VolumeMountParser` struct:

```swift
struct VolumeMountParser {
    let source: String
    let destination: String
    let mode: String?
    
    enum VolumeType {
        case bindMount(hostPath: String)
        case namedVolume(name: String)
        case tmpfs
    }
    
    func parse() throws -> (type: VolumeType, options: [String]) {
        // Parse logic here
    }
}
```

#### c) Environment Variable Processing
- **Location**: `Sources/Container-Compose/Commands/ComposeUp.swift`
- **Opportunity**: Environment variable substitution is done with simple string operations
- **Recommendation**: Implement a proper template engine for environment variables:

```swift
struct EnvironmentVariableEvaluator {
    func evaluate(_ expression: String, context: [String: String]) throws -> String {
        // Support ${VAR}, ${VAR:-default}, ${VAR:?error} patterns
    }
}
```

### 3. Missing Test Cases

#### a) Compose File Parsing Tests
- **Missing**: Tests for edge cases in YAML parsing:
  - Circular references in `extends`
  - Invalid compose file formats
  - Conflicting field values (e.g., both image and build specified)
  - Edge cases in variable interpolation

#### b) Runtime Integration Tests
- **Missing**: Tests for runtime state transitions:
  - Container lifecycle events in different scenarios
  - Error conditions during container operations
  - Concurrent container operations

#### c) Network and Volume Tests
- **Missing**: Tests for network and volume operations:
  - Network creation with various IPAM configurations
  - Volume mount validation
  - External volume/network handling

#### d) Test for Security Features
- **Location**: `Tests/Container-Compose-DynamicTests/`
- **Missing**: Comprehensive tests for security-related compose features:
  - Capabilities (cap_add/cap_drop)
  - Security options
  - User and group configurations
  - Read-only filesystems

### 4. Documentation Gaps

#### a) Error Codes Documentation
- **Issue**: Errors are defined but not documented systematically
- **Recommendation**: Create a comprehensive error reference document:

```markdown
# Error Codes Reference

## ComposeError
- `invalidProjectName`: Project name cannot be resolved
- `externalVolumeNotFound`: Referenced external volume does not exist
- `imageNotFound`: Image reference is missing and cannot be inferred

## RuntimeError
- `notFound(id:)`: Container does not exist
- `alreadyExists(id:)`: Container already exists
- `invalidState(id:expected:actual:)`: Container is in wrong state for operation
```

#### b) API Contract Documentation
- **Missing**: Complete documentation of the Runtime protocol contract:
  - Expected behavior for each method
  - Error conditions and their meanings
  - Concurrency guarantees

## Priority Recommendations

### High Priority
1. **Add missing tests for network operations** - Currently network create/delete only tested through CLI integration
2. **Fix error handling consistency** - Establish unified error mapping across all runtime implementations
3. **Document abstraction leaks** - Create concrete plans to close the identified leaks

### Medium Priority
4. **Refactor volume mount handling** - Extract into dedicated parser struct for better testability
5. **Add compose file validation** - Implement comprehensive validation before runtime operations
6. **Improve environment variable processing** - Use proper template parsing instead of string operations

### Low Priority
7. **Add performance benchmarks** - Especially for large compose files with many services
8. **Implement compose file linting** - Provide helpful warnings for common issues
9. **Add migration path documentation** - From Docker Compose to Container-Compose

## Conclusion

Container-Compose demonstrates excellent architectural design with clear separation of concerns and thoughtful abstractions. The main areas for improvement are in consistency of error handling, completeness of test coverage, and closing known abstraction leaks. Addressing these issues will significantly improve the reliability and maintainability of the codebase.

The project's roadmap for phased improvements (documented in docs/plans/) is well-structured and provides a clear path forward for addressing the identified issues.
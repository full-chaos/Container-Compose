# Container-Compose Review Implementation Plan

**Date:** 2026-05-03  
**Status:** Draft  
**Priority:** High

---

## Executive Summary

This plan implements findings from the comprehensive Container-Compose review, organized into phases that maximize parallelization while respecting dependencies. The plan addresses **24 specific tasks** identified in the review, grouped into **3 priority tiers**.

### Overview

- **High Priority (Phase 1)**: 6 tasks - Testing and error handling foundation
- **Medium Priority (Phase 2)**: 10 tasks - Core refactoring and validation
- **Low Priority (Phase 3)**: 8 tasks - Documentation, benchmarks, and enhancements

**Estimated Total Effort**: ~40-60 hours of development + testing
**Parallelization Potential**: 70% of tasks can be done in parallel within phases

---

## Phase 1: High Priority (Foundation & Testing)

### Goal: Establish proper testing infrastructure and fix critical inconsistencies

#### Task 1.1: Audit Command Naming Consistency
**Location**: `Sources/Container-Compose/Commands/*.swift`  
**Parallelizable**: Yes (independent per command file)

**Description**: Systematically audit all command implementations for project/container naming consistency issues similar to the ComposeUp/ComposeDown bug (commit 1f0451f).

**Tasks**:
- [ ] Review ComposeDown.swift for container_name handling
- [ ] Review ComposeCreate.swift for naming logic  
- [ ] Review ComposeRun.swift for naming consistency
- [ ] Create `effectiveContainerName()` helper if missing
- [ ] Update all call sites to use consistent helper

**Dependencies**: None  
**Parallel With**: Tasks 1.2, 1.3, 1.4, 1.5, 1.6  
**Estimated Effort**: 2-3 hours

#### Task 1.2: Fix Error Handling Consistency
**Location**: `Sources/Container-Compose/Runtime/*.swift`  
**Parallelizable**: Yes (per conformer)

**Description**: Establish unified error mapping across `BridgeContainerClientRuntime` and `AppleContainerizationRuntime`.

**Tasks**:
- [ ] Document error mapping strategy in Runtime protocol docs
- [ ] Update `BridgeContainerClientRuntime.get()` to match pattern  
- [ ] Update `AppleContainerizationRuntime.get()` for consistency
- [ ] Create helper function: `mapError(_:)` in common location
- [ ] Add error handling unit tests for each conformer

**Dependencies**: None  
**Parallel With**: Tasks 1.1, 1.3, 1.4, 1.5, 1.6  
**Estimated Effort**: 3-4 hours

#### Task 1.3: Add Network Operations Tests
**Location**: `Tests/Container-Compose-DynamicTests/`  
**Parallelizable**: Yes (per network test scenario)

**Description**: Implement comprehensive tests for network create/delete operations currently only tested through CLI integration.

**Tasks**:
- [ ] Create `NetworkOperationsTests.swift`
- [ ] Test network creation with basic parameters
- [ ] Test network creation with IPAM configurations
- [ ] Test network deletion
- [ ] Test external network handling
- [ ] Add integration tests for Compose network definition parsing

**Dependencies**: None  
**Parallel With**: Tasks 1.1, 1.2, 1.4, 1.5, 1.6  
**Estimated Effort**: 4-5 hours

#### Task 1.4: Add Security Feature Tests
**Location**: `Tests/Container-Compose-DynamicTests/`  
**Parallelizable**: Yes (per security feature)

**Description**: Implement tests for security-related compose features currently missing comprehensive coverage.

**Tasks**:
- [ ] Create `SecurityFeaturesTests.swift`
- [ ] Test capabilities (cap_add/cap_drop)
- [ ] Test security options parsing
- [ ] Test user/group configurations  
- [ ] Test read-only filesystem handling
- [ ] Add tests for privileged mode

**Dependencies**: None  
**Parallel With**: Tasks 1.1, 1.2, 1.3, 1.5, 1.6  
**Estimated Effort**: 4-5 hours

#### Task 1.5: Add Runtime State Transition Tests
**Location**: `Tests/Container-Compose-StaticTests/`  
**Parallelizable**: Yes (per container state)

**Description**: Implement tests for runtime state transitions and error conditions.

**Tasks**:
- [ ] Create `RuntimeStateTransitionTests.swift`
- [ ] Test created → running transitions
- [ ] Test running → stopped transitions  
- [ ] Test error conditions (alreadyExists, notFound)
- [ ] Test concurrent container operations
- [ ] Add lifecycle event tests

**Dependencies**: Task 1.2 (for error handling consistency)  
**Parallel With**: Tasks 1.1, 1.3, 1.4, 1.6  
**Estimated Effort**: 5-6 hours

#### Task 1.6: Implement Error Codes Documentation
**Location**: `docs/guides/error-codes.md`  
**Parallelizable**: Yes (per error type)

**Description**: Create comprehensive error reference documentation.

**Tasks**:
- [ ] Create `docs/guides/error-codes.md`
- [ ] Document ComposeError types
- [ ] Document RuntimeError types  
- [ ] Document error handling best practices
- [ ] Add troubleshooting examples

**Dependencies**: Task 1.2 (for error mapping consistency)  
**Parallel With**: Tasks 1.1, 1.3, 1.4, 1.5  
**Estimated Effort**: 2-3 hours

**Phase 1 Summary**: 6 tasks, 18-26 hours estimated, can be mostly parallelized

---

## Phase 2: Medium Priority (Core Refactoring)

### Goal: Improve code organization and add missing validation

#### Task 2.1: Extract Volume Mount Parser
**Location**: `Sources/Container-Compose/Commands/ComposeUp.swift`  
**Parallelizable**: Yes (parser can be extracted first)

**Description**: Extract volume mount logic from `configVolume` into dedicated struct for better testability.

**Tasks**:
- [ ] Create `Sources/Container-Compose/VolumeMountParser.swift`
- [ ] Implement volume type detection (bind/named/tmpfs)
- [ ] Extract parsing logic from existing `configVolume`
- [ ] Add unit tests for VolumeMountParser
- [ ] Update ComposeUp.swift to use new parser

**Dependencies**: None  
**Parallel With**: Tasks 2.2, 2.3, 2.4, 2.5, 2.6, 2.7, 2.8  
**Estimated Effort**: 4-5 hours

#### Task 2.2: Add Compose File Validation
**Location**: `Sources/Container-Compose/Codable Structs/DockerCompose.swift`  
**Parallelizable**: Yes (per validation rule)

**Description**: Implement comprehensive compose file validation before runtime operations.

**Tasks**:
- [ ] Add `DockerCompose.validate()` method
- [ ] Validate required field combinations (image/build)
- [ ] Validate port format consistency  
- [ ] Validate resource constraint ranges
- [ ] Add validation error types
- [ ] Add validation tests

**Dependencies**: None  
**Parallel With**: Tasks 2.1, 2.3, 2.4, 2.5, 2.6, 2.7, 2.8  
**Estimated Effort**: 4-5 hours

#### Task 2.3: Implement Environment Variable Template Engine
**Location**: `Sources/Container-Compose/EnvironmentVariableEvaluator.swift`  
**Parallelizable**: Yes (per template pattern)

**Description**: Replace simple string operations with proper template parsing.

**Tasks**:
- [ ] Create `EnvironmentVariableEvaluator.swift`
- [ ] Implement `${VAR}` substitution
- [ ] Add default value syntax `${VAR:-default}`
- [ ] Implement error syntax `${VAR:?error message}`  
- [ ] Add context for service/project variables
- [ ] Write comprehensive tests

**Dependencies**: None  
**Parallel With**: Tasks 2.1, 2.2, 2.4, 2.5, 2.6, 2.7, 2.8  
**Estimated Effort**: 3-4 hours

#### Task 2.4: Add Compose File Parsing Edge Case Tests
**Location**: `Tests/Container-Compose-StaticTests/`  
**Parallelizable**: Yes (per edge case)

**Description**: Add tests for YAML parsing edge cases.

**Tasks**:
- [ ] Create `ComposeParsingEdgeCaseTests.swift`
- [ ] Test circular references in extends
- [ ] Test invalid compose formats
- [ ] Test conflicting field values (image+build)
- [ ] Test variable interpolation edge cases
- [ ] Add malformed YAML handling tests

**Dependencies**: Task 2.2 (compose validation)  
**Parallel With**: Tasks 2.1, 2.3, 2.5, 2.6, 2.7, 2.8  
**Estimated Effort**: 4-5 hours

#### Task 2.5: Add Network and Volume Validation Tests
**Location**: `Tests/Container-Compose-DynamicTests/`  
**Parallelizable**: Yes (per validation scenario)

**Description**: Implement tests for network/volume mount validation.

**Tasks**:
- [ ] Create `VolumeMountValidationTests.swift`
- [ ] Test bind mount validation
- [ ] Test named volume resolution
- [ ] Test external volume/network handling
- [ ] Add mount path existence checks
- [ ] Test read/write mode validation

**Dependencies**: Task 2.1 (volume parser)  
**Parallel With**: Tasks 2.1, 2.2, 2.3, 2.4, 2.6, 2.7, 2.8  
**Estimated Effort**: 5-6 hours

#### Task 2.6: Add Volume Mount Integration Tests
**Location**: `Tests/Container-Compose-DynamicTests/`  
**Parallelizable**: Yes (per volume scenario)

**Description**: Create integration tests for complex volume scenarios.

**Tasks**:
- [ ] Test multiple volumes in single service
- [ ] Test volume inheritance in extends
- [ ] Test volume with complex paths
- [ ] Test volume permission handling  
- [ ] Add named volume lifecycle tests

**Dependencies**: Tasks 2.1, 2.5  
**Parallel With**: Tasks 2.2, 2.3, 2.4, 2.7, 2.8  
**Estimated Effort**: 4-5 hours

#### Task 2.7: Implement Compose File Linting
**Location**: `Sources/Container-Compose/Linter.swift`  
**Parallelizable**: Yes (per lint rule)

**Description**: Create compose file linter for common issues.

**Tasks**:
- [ ] Create `Sources/Container-Compose/Linter.swift`
- [ ] Implement unused network/volume detection
- [ ] Add image exists validation (if possible)
- [ ] Check for deprecated syntax patterns
- [ ] Implement helpful warning messages
- [ ] Add linter tests

**Dependencies**: Task 2.2 (compose validation)  
**Parallel With**: Tasks 2.1, 2.3, 2.4, 2.5, 2.6, 2.8  
**Estimated Effort**: 3-4 hours

#### Task 2.8: Add Environment Variable Edge Case Tests
**Location**: `Tests/Container-Compose-DynamicTests/`  
**Parallelizable**: Yes (per edge case)

**Description**: Add comprehensive tests for environment variable processing.

**Tasks**:
- [ ] Create `EnvironmentVariableEdgeCaseTests.swift`
- [ ] Test undefined variable handling
- [ ] Test default value substitution  
- [ ] Test recursive variable references
- [ ] Add project env injection tests
- [ ] Test special character handling

**Dependencies**: Task 2.3 (env template engine)  
**Parallel With**: Tasks 2.1, 2.2, 2.4, 2.5, 2.6, 2.7  
**Estimated Effort**: 4-5 hours

**Phase 2 Summary**: 8 tasks, 30-41 hours estimated, high parallelization potential

---

## Phase 3: Low Priority (Documentation & Enhancements)

### Goal: Improve documentation and add advanced features

#### Task 3.1: Add API Contract Documentation
**Location**: `docs/guides/runtime-protocol.md`  
**Parallelizable**: Yes (per method)

**Description**: Create complete documentation for Runtime protocol contract.

**Tasks**:
- [ ] Create `docs/guides/runtime-protocol.md`
- [ ] Document expected behavior for each method
- [ ] Specify error conditions and meanings  
- [ ] Add concurrency guarantees documentation
- [ ] Include usage examples for each method

**Dependencies**: None  
**Parallel With**: Tasks 3.2, 3.3, 3.4, 3.5, 3.6, 3.7, 3.8  
**Estimated Effort**: 5-6 hours

#### Task 3.2: Add Performance Benchmarks
**Location**: `Sources/Container-Compose/Benchmarks/`  
**Parallelizable**: Yes (per scenario)

**Description**: Create benchmark suite for performance regression detection.

**Tasks**:
- [ ] Create `Sources/Container-Compose/Benchmarks/`
- [ ] Benchmark small compose files (1 service)
- [ ] Benchmark medium compose files (5 services)  
- [ ] Benchmark large compose files (20+ services)
- [ ] Add YAML parsing benchmarks
- [ ] Add volume mount parsing benchmarks
- [ ] Create baseline measurements

**Dependencies**: None  
**Parallel With**: Tasks 3.1, 3.3, 3.4, 3.5, 3.6, 3.7, 3.8  
**Estimated Effort**: 4-5 hours

#### Task 3.3: Add Migration Documentation
**Location**: `docs/guides/migration-from-docker-compose.md`  
**Parallelizable**: Yes (per feature gap)

**Description**: Create migration guide from Docker Compose to Container-Compose.

**Tasks**:
- [ ] Create `docs/guides/migration-from-docker-compose.md`
- [ ] Document supported features matrix
- [ ] Add workarounds for unsupported features  
- [ ] Create troubleshooting section
- [ ] Add real-world migration examples

**Dependencies**: None  
**Parallel With**: Tasks 3.1, 3.2, 3.4, 3.5, 3.6, 3.7, 3.8  
**Estimated Effort**: 4-5 hours

#### Task 3.4: Implement Abstract ListenAddress Probe
**Location**: `Sources/Container-Compose/Commands/TCPProbe.swift`  
**Parallelizable**: No (single abstraction task)

**Description**: Create `ListenAddress.isAlreadyBound()` to encapsulate transport awareness.

**Tasks**:
- [ ] Create `ListenAddress.isAlreadyBound() -> Bool` method
- [ ] Update idempotence probe to use new method
- [ ] Add unit tests for ListenAddress methods
- [ ] Verify TCP/Unix socket behavior

**Dependencies**: None  
**Parallel With**: Tasks 3.1, 3.2, 3.3, 3.5, 3.6, 3.7, 3.8  
**Estimated Effort**: 2-3 hours

#### Task 3.5: Add Compose Feature Coverage Documentation
**Location**: `docs/compose-feature-coverage.md`  
**Parallelizable**: Yes (per feature)

**Description**: Create detailed feature coverage documentation.

**Tasks**:
- [ ] Create `docs/compose-feature-coverage.md`
- [ ] Document all supported top-level keys
- [ ] Add service-level feature matrix
- [ ] Include examples for each supported feature
- [ ] Document partial/unsupported features clearly

**Dependencies**: None  
**Parallel With**: Tasks 3.1, 3.2, 3.3, 3.4, 3.6, 3.7, 3.8  
**Estimated Effort**: 4-5 hours

#### Task 3.6: Add Debug Logging Configuration
**Location**: `Sources/Container-Compose/Commands/*.swift`  
**Parallelizable**: Yes (per command)

**Description**: Implement structured debug logging with configurable levels.

**Tasks**:
- [ ] Create logging infrastructure
- [ ] Add debug flag to all commands
- [ ] Implement verbose output for parsing steps
- [ ] Add runtime operation logging
- [ ] Create log format specification

**Dependencies**: None  
**Parallel With**: Tasks 3.1, 3.2, 3.3, 3.4, 3.5, 3.7, 3.8  
**Estimated Effort**: 4-5 hours

#### Task 3.7: Add Runtime Feature Detection
**Location**: `Sources/Container-Compose/RuntimeFeatureDetector.swift`  
**Parallelizable**: Yes (per runtime capability)

**Description**: Create comprehensive feature detection for different runtimes.

**Tasks**:
- [ ] Create `RuntimeFeatureDetector.swift`
- [ ] Detect network CRUD capabilities
- [ ] Detect secrets management support  
- [ ] Detect volume driver support
- [ ] Add feature fallback strategies
- [ ] Create capability reporting

**Dependencies**: None  
**Parallel With**: Tasks 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.8  
**Estimated Effort**: 4-5 hours

#### Task 3.8: Create Extension Points Documentation
**Location**: `docs/guides/extensions.md`  
**Parallelizable**: Yes (per extension type)

**Description**: Document extension points for third-party integrations.

**Tasks**:
- [ ] Create `docs/guides/extensions.md`
- [ ] Document runtime extension points
- [ ] Add command extension examples  
- [ ] Create sample integrations
- [ ] Document best practices for extensions

**Dependencies**: None  
**Parallel With**: Tasks 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7  
**Estimated Effort**: 4-5 hours

**Phase 3 Summary**: 8 tasks, 28-39 hours estimated, mostly parallelizable

---

## Implementation Timeline

### Week 1: Phase 1 (Foundation)
- **Days 1-2**: Tasks 1.1, 1.2, 1.6 (network consistency + error docs)
- **Days 3-5**: Tasks 1.3, 1.4, 1.5 (comprehensive test suites)

### Week 2: Phase 2 (Refactoring)
- **Days 1-3**: Tasks 2.1, 2.2, 2.3 (parser extraction + validation)
- **Days 4-5**: Tasks 2.4, 2.5, 2.6 (validation tests)

### Week 3: Phase 2 + Phase 3
- **Days 1-2**: Tasks 2.7, 2.8 (linting + edge case tests)
- **Days 3-5**: Tasks 3.1, 3.2, 3.3 (docs + benchmarks)

### Week 4: Phase 3 Completion
- **Days 1-4**: Tasks 3.4, 3.5, 3.6, 3.7 (advanced features)
- **Day 5**: Task 3.8 + Final review and testing

---

## Success Criteria

### Phase 1 Completion
- [ ] All commands use consistent container naming logic
- [ ] Error handling is unified across runtimes  
- [ ] Network operations have comprehensive tests
- [ ] Security features are fully tested
- [ ] Runtime state transitions are covered by tests

### Phase 2 Completion  
- [ ] Volume mount logic is extracted and tested
- [ ] Compose file validation runs before runtime operations
- [ ] Environment variable processing uses proper template engine
- [ ] All parsing edge cases have tests
- [ ] Volume mount validation and integration tests pass

### Phase 3 Completion
- [ ] Runtime protocol contract is fully documented
- [ ] Performance benchmarks establish baseline
- [ ] Migration guide covers common use cases
- [ ] Debug logging is configurable and helpful

---

## Risk Assessment & Mitigation

### Technical Risks
- **Apple Container API Changes**: Regularly sync with upstream changes  
  *Mitigation: Subscribe to apple/container release notifications*

- **Test Coverage Gaps**: Start with existing tests, build incrementally  
  *Mitigation: Focus on critical paths first (network ops, error handling)*

- **Performance Degradation**: Profile before and after major refactorings  
  *Mitigation: Establish benchmarks early (Task 3.2)*

### Schedule Risks
- **Complexity Underestimation**: Buffer time for each phase  
  *Mitigation: Add 20% buffer to estimates*

- **Dependency Delays**: Parallelize tasks as much as possible  
  *Mitigation: Focus on independent tasks first (Week 1)*

---

## Conclusion

This implementation plan provides a systematic approach to addressing all review findings while maximizing parallelization. The phased approach allows for incremental progress and early wins, with clear success criteria at each stage.

The plan prioritizes testing infrastructure and consistency fixes first (Phase 1), followed by core refactoring improvements (Phase 2), and finally documentation and enhancements (Phase 3). This ordering ensures that even if the project timeline is constrained, the most critical improvements are completed first.

**Estimated Total Timeline**: 4 weeks with dedicated development time
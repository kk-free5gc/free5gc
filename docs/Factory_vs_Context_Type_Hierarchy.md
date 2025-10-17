# Factory vs Context Type Hierarchy

## Factory Layer (Configuration Structs)

```go
// Different config structs for different YAML structures
type UEIPPool struct {           // IPv4 config
    Cidr string `yaml:"cidr"`
}

type UEIPv6Pool struct {         // IPv6 config  
    Prefix         string `yaml:"prefix"`
    UePrefixLength int    `yaml:"uePrefixLength"`
    IidAllocation  string `yaml:"iidAllocation"`
}
```

**Why separate?**  
IPv4 and IPv6 have different configuration parameters in YAML.

---

## Context Layer (Runtime Structs)

```go
// Unified runtime pool allocator
type UeIPPool struct {
    ueSubNet *net.IPNet          // Works for both IPv4 and IPv6
    pool     *pool.LazyReusePool // Allocation mechanism is the same
}
```

**Why unified?**  
Both IPv4 and IPv6 use the same allocation algorithm at runtime.

---

## The Pattern

| Factory (Config) | Context (Runtime) |
|------------------|-------------------|
| UEIPPool         | → UeIPPool (unified allocator) |
| UEIPv6Pool       | → UeIPPool (unified allocator) |

---

## Conversion Functions

- `NewUEIPPool(factory.UEIPPool) → context.UeIPPool`
- `NewUEIPv6Pool(factory.UEIPv6Pool) → context.UeIPPool`

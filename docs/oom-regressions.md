# Allocation-failure regressions: before and after

## Setup

Verified with Zig 0.16.0 on aarch64 macOS. The baseline is commit
`0f982c4` (v0.5.1); the fixed version is the working tree on
`fix/regex-allocation-and-literal`. Both versions execute the exact same
`src/oomtest.zig`, using deterministic allocator failure injection. No actual
system memory exhaustion is required.

The tests use the public API and are included in `zig build test` through
`src/root.zig`.

## Reproduce the fixed version

From the repository root:

```sh
zig test src/oomtest.zig --test-filter 'OOM regression'
```

Observed result:

```text
1/3 oomtest.test.OOM regression: scratch result growth remains safe to destroy...OK
2/3 oomtest.test.OOM regression: Pike thread creation does not leak...OK
3/3 oomtest.test.OOM regression: collected capture append does not leak...OK
All 3 tests passed.
```

## Reproduce the original version

Export the old sources into an isolated temporary directory, then copy only
our new test file into that directory. This leaves the working tree intact.

```sh
repro_dir=$(mktemp -d /tmp/regex-oom-before.XXXXXX)
git archive 0f982c4 | tar -x -C "$repro_dir"
cp src/oomtest.zig "$repro_dir/src/oomtest.zig"
cd "$repro_dir"
```

Run each case separately: the first intentionally crashes the old engine,
so a single combined run would stop before checking the other cases.
Each command below is expected to exit nonzero on the baseline.

```sh
zig test src/oomtest.zig --test-filter 'OOM regression: scratch'
zig test src/oomtest.zig --test-filter 'OOM regression: Pike'
zig test src/oomtest.zig --test-filter 'OOM regression: collected'
```

## Observed comparison

| Case | Original v0.5.1 | Fixed working tree |
|---|---|---|
| Scratch result growth | Segmentation fault during `Scratch.deinit`; test process terminated with ABRT | Pass; expected `OutOfMemory`, safe cleanup |
| Pike thread creation | `MemoryLeakDetected`, 24 bytes leaked | Pass at every injected allocation failure |
| Collected capture append | `MemoryLeakDetected`, 32 bytes leaked | Pass at every injected allocation failure |

Byte counts and the exact crash signal are platform-dependent. The relevant
invariants are valid ownership after failure and complete cleanup.

### 1. Scratch result buffer: stale pointer after failed growth

The minimal trigger is:

```zig
var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
var scratch = regex.Scratch.init(failing.allocator());
defer scratch.deinit();
_ = try scratch.resultBuf(2);
failing.fail_index = failing.alloc_index;
try std.testing.expectError(error.OutOfMemory, scratch.resultBuf(8));
```

The old implementation frees the two-slot buffer before allocating its
replacement. When allocation fails, `scratch.result` still points to the
freed buffer. `deinit` attempts to free it again. The fix allocates the new
buffer before releasing and replacing the old one.

Observed baseline stack excerpt:

```text
Segmentation fault
src/exec.zig:339:40 in deinit
    if (self.result.len > 0) a.free(self.result);
```

### 2. Pike VM: partially constructed thread is not owned

Compile `(a|b)+` and match 40,000 ASCII `a` bytes to select the Pike VM.
`checkAllAllocationFailures` first runs successfully, then repeats the
operation with each successive allocation forced to fail.

On the baseline, failing the capture-array allocation after creating a
`Thread` leaks the thread because it has not yet entered `all_threads`.
The fix reserves management-list capacity first and installs an `errdefer`
for the newly created thread.

Observed baseline excerpt:

```text
fail_index: 7/20
allocated bytes: 408
freed bytes: 384
FAIL (MemoryLeakDetected)
```

The failed allocation is `t.cap = ... allocator.alloc(i64, m.ncap)`;
the leaked allocation is `allocator.create(Thread)`.

### 3. Collected captures: copied slice lost on append failure

Compile `(a|b)+`, then collect submatch indices from
`aa bb aa bb aa bb aa bb aa bb aa bb`. Inject allocation failures in
`findAllSubmatchIndex`.

The old expression allocates a copy before appending it:

```zig
try out.append(allocator, try allocator.dupe(i64, m));
```

If the outer list cannot grow, the copy is not in the list and its cleanup
loop cannot find it. The fix adds an `errdefer` for the copy until the append
succeeds.

Observed baseline excerpt:

```text
fail_index: 6/20
allocated bytes: 644
freed bytes: 612
FAIL (MemoryLeakDetected)
```

The leaked 32 bytes hold four `i64` offsets: the complete match and one
capturing group.

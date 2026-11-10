# Native ownership audit

## Immutable scope and provenance

Baseline: `7c1a7bcbd3eead32644b6800937540fb95457801`.
Guidance: `miyako/skills`, `4d-skills/skills/4dplugin/SKILL.md` at
`e6b492fcb81e5e1a7f7db723594b420e63bf6eb9`, read through the immutable
GitHub contents API, without another checkout. The header's `rev : v14`
is not an independently verified upstream SDK release identifier.

The harness checks these Git blob IDs before compiling the **complete,
unchanged** bundled SDK implementation and headers:

| SDK path under `4D Plugin API/` | Baseline blob |
|---|---|
| `4DPluginAPI.c` | `e0f36efeb4c27f4f471f037b59a9cdda3b17af7a` |
| `4DPluginAPI.h` | `21a935499d790c33ca5d09819174b564c027c5d3` |
| `EntryPoints.h` | `730f2f77ff2713fb2fe4b7d6562baeedf5f664cb` |
| `Flags.h` | `a8c14a17b53d8f38f8d06a047e9a8190367dec55` |
| `PrivateTypes.h` | `77053dc0c0a3718d2d3b6f158371a6af78c6ae66` |
| `PublicTypes.h` | `2bb392e73e9c556c274fe0a75b3a6b83e310b77c` |
| `4DPluginAPI.def` | `996ecc4ab11ad165de9192eba2e7478db141c757` |

Baseline edited helper blobs: `Classes/C_PICTURE.cpp`
`73da2f1a502863d0c06638092f4d6f455e21021d` and `Classes/C_POINTER.cpp`
`b2bcbc66a4481a4b9b1d08e09dcbe277eb621b10`.
`Classes/ARRAY_TEXT.cpp` is
`534855e0959020ce9a66cef08f8434799c174495`; `Classes/C_TEXT.cpp` is
`45ea6432dff52b681a5c6a7cea58ad5fc15df66b`. Both remain unchanged.

Prior art was read as immutable files from
`miyako/4d-plugin-picture-to-ico` at
`656c0bc9577de01cf19f761a31a918d375f64609`:
`ownership_host.mm`, `ownership_platform.h`, `test_ownership.py` under
`.github/tests/`, and the picture/pointer/command-argument wrappers under
`4D Plugin API/Classes/`. The target SDK blob IDs differ. Its harness and
owner helper were adapted to Ping's actual sources, ABI, SDK selectors and
network boundaries; its results were not reused.

## Complete tracked native inventory and build memberships

`git ls-files` identifies exactly 18 native translation units: root
`4DPlugin.cpp`, bundled `4DPluginAPI.c`, and all 16 `Classes/*.cpp` below.
Both `Ping.vcxproj` and `Ping.xcodeproj/project.pbxproj` compile all 18.
Each wrapper has a matching tracked `.h`; `Classes/C_TYPES.h` is the shared
UTF-8/UTF-16/vector and platform type helper. Root `4DPlugin.h` contains the
dispatcher declarations and packed ICMP structures. `4D Plugin_Prefix.pch`
imports Carbon. The six SDK C/ABI headers and `.def` above are protected,
not wrapper code to rewrite. No other tracked C/C++/Objective-C sources
or alternate SDK copies were excluded as dormant.

| Wrapper implementations and matching headers | Ownership surface |
|---|---|
| `ARRAY_TEXT` | Borrowed array elements copied into independent C++ strings; newly created distinct strings shallow-transferred on accepted output assignments. Includes unused Objective-C and path helpers. |
| `ARRAY_BOOLEAN`, `ARRAY_DATE`, `ARRAY_INTEGER`, `ARRAY_LONGINT`, `ARRAY_REAL`, `ARRAY_TIME` | Numeric/date/time/bit arrays, no owned text handoff. Their SDK resize failure limits still apply. |
| `C_TEXT` | Copies incoming text into a C++ owner; parameter/return output uses engine-backed `PA_SetUnistring`, not array transfer. UTF-8/UTF-16 and Objective-C/path helpers included. |
| `C_PICTURE` / internal `CPicture` | Dormant from the Ping command but compiled on both platforms. File-path scalar arguments, conversion buffers, owning command results, picture creation/retention/output lifetimes and metadata handles. |
| `C_POINTER` | Dormant owning `PA_GetPointerValue` scratch result and legacy variable/field reference-descriptor construction. |
| `C_BLOB` / internal `CBytes` | Byte vectors and handle transfer/copy helpers, hex/base64 conversions use independent `C_TEXT`; no shallow text ownership transfer. |
| `C_DATE`, `C_INTEGER`, `C_LONGINT`, `C_REAL`, `C_TIME` | Scalar numeric/date/time parameters and returns, no string owner. |

`4DPluginAPI.def` exports `FourDPackex`; the SDK routes it to `PluginMain`
and the root dispatcher. `manifest.json` declares the sole command
`HOST Ping(&T;&Y;&L;&L):L`: text hostname, text response array, two longints,
longint result. No scalar-only or internal command paths were excluded.
`HOST_Ping` creates independent response messages and an independent input
hostname; it does not share array owners with callbacks. No plugin-side
method callbacks, delayed callbacks, object-property or collection-element
getters/handoffs exist in these tracked native sources. This SDK has no
modern object/collection value kinds or APIs: counters are **not applicable**,
not a claim that unexecuted object/collection behavior is safe. Indexed absence
alone is not the safety argument: the actual dispatcher, helpers and SDK
contracts were traced as above. Prebuilt bundles and 4D database/user-preference
files were not opened, executed, regenerated or modified.

## Exact SDK contracts and surgical corrections

Line references here are to the immutable baseline `4DPluginAPI.c`.

| API / lines | Contract and action |
|---|---|
| `PA_CreateUnistring` / 244; `PA_SetUnistring` / 263 | Engine creation/content-setter boundary. Shim models successful independent content ownership with allocated and null empty representations; no allocation-failure guarantee is inferred. |
| `PA_SetStringVariable` / 3826 | Shallow assignment, no disposal of overwritten owner. Picture-command text slots now begin Undefined, transfer one created owner, and clear once. No blanket removal of scalar cleanup. |
| `PA_GetStringInArray` / 4266; `PA_SetStringInArray` / 4444 | Getter borrows. Setter disposes old then shallow-assigns only for Unicode kind, non-null data, `0 <= index <= count`, non-null descriptor. Index zero is accepted. `ARRAY_TEXT` already copies before mutation and transfers distinct owners without post-transfer disposal; preserved. Rejections retain caller ownership. |
| `PA_CreateVariable` / 3523 | Creating a text or picture variable may create an empty owner. Undefined initialization avoids overwriting it. The file-path output picture remains an owning argument and is retained into the wrapper before argument cleanup. |
| `PA_CreatePicture` / 380; `PA_DuplicatePicture` / 447; `PA_GetPictureVariable` / 3730 | Creation owns; duplicate with `retainOnly=1` retains; getter borrows from variable. `setBytes` releases the temporary creation owner after retention and checks error before adopting unspecified failure output. Returned/parameter pictures retain independently. |
| `PA_ConvertCharsetToCharset` / 4776 | Returns **bytes**, not UTF-16 units. `createCopy` checks error, divides by `sizeof(PA_Unichar)`, preserves exact content/terminator, and avoids the baseline overread. |
| `PA_ExecuteCommandByID` / 5257 | Success returns an independent variable owner; failure may return raw kind 0 or unspecified output. New noncopyable `CommandArguments` owns initialized arguments, clears only successful results, checks error before inspection/adoption, and unwinds arguments on failure. Borrowed input pictures get an independent retained argument; returned pictures retain before argument clear. No kind normalization of failed output. |
| `PA_GetPointerValue` / 2035 and header cleanup comment | Success is an owning scratch value. `C_POINTER` preserves existing descriptor construction, then clears the scratch owner; failure throws before reading its unspecified union or changing the destination. No redesign of the legacy descriptor API is claimed. |

`std::runtime_error` explicitly surfaces helper failure to its caller, rather
than returning an empty success. The existing exported command's error behavior
is unchanged; it does not call these picture/pointer helpers.

## Offline evidence and reproduction

Run on macOS with Apple clang, no dependency installation:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 .github/tests/test_ownership.py -v
```

The runner compiles the complete SDK, all 16 actual wrappers, and actual root
dispatcher as Objective-C++ with ASan and UBSan, into a temporary unsigned
executable. The packed legacy SDK layout requires disabling UBSan's alignment
check; other undefined-behavior checks and ASan remain enabled. LeakSanitizer is
disabled on macOS; explicit allocation/refcount/handle ledgers must reach zero.
Unexpected engine selectors terminate the process.

Every translation unit is force-included with `ownership_platform.h` **before**
compilation. All network/DNS/socket/send/receive/select/address-format/process-ID/
time/Carbon-clock calls made by the macOS source and URL/image helper boundaries
are synthetic replacements. `nm -u` rejects real imports for these and additional
network/process/file-URL boundaries. Fixtures use only `synthetic.invalid`, an
in-memory address descriptor, fake socket 42, fake PID 123, fabricated packets,
byte arrays and deterministic time. No real host resolution, packets, real
hosts/private addresses, system configuration, image/filesystem operations or
user data are involved.

The **same final harness** was run with `OWNERSHIP_SOURCE_ROOT` pointing to an
archive extracted using:

```sh
git archive 7c1a7bcbd3eead32644b6800937540fb95457801 \
  '4D Plugin API' 4DPlugin.cpp 4DPlugin.h | tar -x -C "$NATIVE_BASELINE_DIRECTORY"
OWNERSHIP_SOURCE_ROOT="$NATIVE_BASELINE_DIRECTORY" \
  PYTHONDONTWRITEBYTECODE=1 python3 .github/tests/test_ownership.py -v
```

Create an empty temporary `NATIVE_BASELINE_DIRECTORY` first; this archives only
native source, not databases, binaries or user preferences.

| Final harness | Baseline | Fixed |
|---|---|---|
| Total subprocess leaves | 72: **23 pass, 49 fail** | **72 pass, 0 fail** |
| Unchanged controls | 12 dispatcher + 2 array + 8 scalar + 1 SDK-failure characterization pass | Same 23 pass |
| Confirmed defect regressions | 49 fail | Same 49 pass |

Named failures include `path`: duplicate/unowned string disposal (including
nonempty ASCII/BMP/supplementary text); `copy` ASCII and `copy:conversion`:
ASan heap-buffer-overflow; `bytes`: excess picture retain; `bytes:creation`:
adopting a poisoned failed creation; `gray`/`size`/`thumbnail`: unbalanced
owning command results; `pointer`: unbalanced string allocations;
`pointer-failure`: failure not surfaced. The remaining matrix covers allocated
and null empty text, exact lengths/content, command-return Undefined/string/
picture owners for all five picture commands, and handle/command failures for
each. Each successful leaf asserts `strings=0 pictures=0 handles=0`, with
object/collection counts explicitly not applicable.

Array controls cover element zero, distinct owners, borrowed copy before
replacement, allocator churn, repeated replacement, shrink, clear, Undefined
destination initialization, and rejected kind/data/index/null descriptor.
Scalar controls overwrite the input after reading and destroy the C++ wrapper
before checking independently owned output/return content. Dispatcher controls
execute init plus command 1 with exact reply/timeout messages, DNS failure,
initial socket failure, ICMP socket failure and send failure; synthetic sockets
and DNS descriptors balance. Existing lifecycle tests pass separately (45 tests,
temporary local fixtures/fake GitHub API only).

## Build safety and explicit deferrals

Before validation, both workflows, release/version scripts, pre-push guard,
both projects' compilation memberships and build phases were inspected.
Existing Build and Bump version are **manual only**. Build signs, packages,
notarizes and publishes: it was not invoked or modified. Xcode has resource/
copy/signing configuration and MSBuild imports local platform props; neither
project build is used. New Ownership CI has read-only contents permission,
`macos-latest`, relevant-path filters, and push branches exactly `master` and
`miyako-ping-ownership-audit`; its sole operation is the unsigned offline harness.
No release/tag/publication/manual dispatch is part of this audit.

- **SDK resize/OOM deferred:** `PA_ResizeArray` can change logical element count
  even when physical handle resize fails. The characterization asserts that
  mismatch, restores only the test descriptor, then cleans up. It does not run
  the unsafe wrapper through OOM or claim failure preservation. Void wrapper
  output APIs and protected SDK behavior require a separately designed
  failure-preserving boundary; no speculative SDK rewrite or empty-success
  fallback was added. String allocation, constructor/output-picture allocation
  and general OOM are not certified by successful tests.
- **Picture metadata deferred:** `PA_GetPictureData` documents enumeration and
  representation data but does not state ownership of its returned string.
  `_GetCount` already checks error before reading it. Tests return poisoned
  error output to exercise that boundary; no speculative success disposal or
  claim of metadata allocation balance is made.
- **Native platform/host deferred:** Windows ICMP/Win32 branches and actual 4D
  engine lifetimes, SDK ABI compatibility and network behavior were not
  executed. Offline shim evidence does not certify Windows or real 4D safety.

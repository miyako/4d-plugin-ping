![version](https://img.shields.io/badge/version-18%2B-EB8E5F)
![platform](https://img.shields.io/static/v1?label=platform&message=mac-intel%20|%20mac-arm%20|%20win-64&color=blue)
[![license](https://img.shields.io/github/license/miyako/4d-plugin-ping)](LICENSE)
![downloads](https://img.shields.io/github/downloads/miyako/4d-plugin-ping/total)


# 4d-plugin-ping

The Ping plugin adds a single ICMP-based network reachability command to 4D. It resolves a hostname or IP address and sends ICMP echo requests directly from 4D code — no shelling out to the OS's `ping` binary and parsing text output. On **macOS** it builds and parses raw ICMP packets itself over a `SOCK_DGRAM`/`IPPROTO_ICMP` socket; on **Windows** it calls the OS's own `IcmpSendEcho` API. Results come back as a `Longint` status code plus a `Text` array of human-readable per-attempt lines.

| Command | Returns | Purpose |
|---|---|---|
| [`HOST Ping`](#host-ping) | Longint | Ping a host by name or IP address and collect per-attempt results |

**Platforms:** macOS, Windows

---

## Requirements & platform notes

- **Only IPv4 targets are actually pinged.** If `hostName` resolves solely to IPv6 addresses, the command does not report a distinct error — it returns as if nothing went wrong, but `responses` comes back empty. See [Error handling](#error-handling--troubleshooting).
- **On macOS**, the plugin opens a raw `SOCK_DGRAM`/`IPPROTO_ICMP` socket per resolved address — the same unprivileged-ping mechanism macOS's own `ping(8)` uses, so no elevated privileges should normally be required. If that socket still can't be opened in your deployment (e.g. under restrictive sandboxing), that address's attempts report a distinct error code (`-2`) rather than crashing or hanging.
- **On Windows**, the plugin calls `IcmpSendEcho` via `iphlpapi`/Winsock instead of building raw sockets — no elevated privileges needed there either.
- **`count` is capped to 1–100, and `limit` (per-request timeout, in seconds) is capped to 1–30.** Values outside these ranges are silently clamped, not rejected — there's no way to ask this command for a longer sweep or a longer per-reply wait than that.
- **If `hostName` resolves to more than one IPv4 address, every address is pinged in turn.** `responses` can contain multiple `count`-line blocks back to back — one per resolved address — not just one.
- All four parameters are required. Nothing in the manifest or the parameter-reading code indicates an optional/omittable form.

---

## HOST Ping

### Syntax

```
HOST Ping ( hostName ; responses ; count ; limit ) → Result
```

| Parameter | Type | Description |
|---|---|---|
| `hostName` | Text | Hostname or IP address to resolve and ping. |
| `responses` | Text array | Must be declared by the caller before the call (e.g. `ARRAY TEXT($responses;0)`). Filled by the plugin with one line per ping attempt. |
| `count` | Longint | Number of echo requests to send per resolved address. Clamped to the range 1–100. |
| `limit` | Longint | Per-request timeout, in seconds. Clamped to the range 1–30. |
| Result | Longint | `0` on a clean run with no errors. A non-zero value is a platform/OS-specific error code (see below) — not a documented 4D error enum. |

### Description

`HOST Ping` resolves `hostName` (via `getaddrinfo`, both address families requested) and, for every **IPv4** address returned, sends `count` ICMP echo requests with a `limit`-second timeout each. Each attempt appends one line to `responses`:

- A timeout: `Request timeout for icmp_seq <n>`
- A reply: `<bytes> bytes from <ip>: icmp_seq=<n> ttl=<t> time=<ms> ms`

**On macOS**, round-trip time is measured locally with a monotonic clock around the send/receive pair. **On Windows**, the plugin still measures round-trip time itself the same way, even though `IcmpSendEcho` separately reports its own round-trip time internally — the two aren't the same measurement, though in practice they should be close.

If `hostName` resolves to any **IPv6** addresses, they are silently skipped — no line is appended to `responses` and no error is raised for them specifically.

`Result` reflects, in order of priority as encountered:
- The `getaddrinfo` error code, if resolution itself failed (nothing was pinged, `responses` stays empty).
- The *last* non-timeout, non-success error encountered across all attempts — earlier errors on other pings/addresses in the same call can be silently overwritten by a later success or a different error. Don't rely on `Result` alone to detect a partial failure; check `responses` too.
- `0`, if nothing above applies. (This is the expected "everything succeeded" value; I haven't independently verified that the underlying `Longint` wrapper always default-initializes to `0` when nothing writes to it, so treat `0` as the expected success value rather than an absolutely guaranteed one.)

### Example

```4d
ARRAY TEXT($responses;0)
$result:=HOST Ping("google.com";$responses;4;5)

If ($result=0)
	For ($i;1;Size of array($responses))
		ALERT($responses{$i})
	End for 
Else 
	ALERT("Ping failed with error code: "+String($result))
End if 
```

A quick single-shot reachability check, tuned to fail fast:

```4d
ARRAY TEXT($responses;0)
$result:=HOST Ping("192.168.1.1";$responses;1;2)  // one attempt, 2-second timeout

If (Size of array($responses)>0)
	ALERT($responses{1})
Else 
	ALERT("No response (unreachable, timed out, or an IPv6-only target)")
End if 
```

---

## Error handling & troubleshooting

- **IPv6-only hosts produce no output and no distinct error.** If you know a hostname resolves and `responses` still comes back empty with `Result=0`, check whether it's IPv6-only — this command only pings IPv4 addresses.
- **`Result` is not a full run summary.** It's overwritten by whatever non-timeout error happened last, so a failure buried among otherwise-successful pings (or on an earlier resolved address) can be masked. Always inspect `responses` line by line if you need to know exactly which attempts failed.
- **DNS/resolution failures surface as a raw OS error code, not a 4D error.** If `hostName` can't be resolved at all, `Result` is whatever `getaddrinfo` returned on that platform (POSIX-style resolver codes on macOS, Winsock equivalents on Windows), and `responses` stays empty.
- **`count` and `limit` are silently clamped, not rejected.** Requesting `count` above 100 or `limit` above 30 seconds won't raise an error — it's quietly capped to 100 / 30 instead.
- **A macOS socket-open failure reports `Result=-2` for that address**, with no lines appended for it — this happens if the raw ICMP socket can't be created (e.g. a restrictive sandbox), rather than a hang or crash.
- **`Result=-999` means an internal error was caught mid-run.** This is a plugin-specific sentinel, not an OS or 4D error code. `responses` may be partially filled up to the point where the error occurred.

---

## Quick reference

```4d
ARRAY TEXT($responses;0)
$result:=HOST Ping($hostName;$responses;$count;$limit)

If ($result=0)
	For ($i;1;Size of array($responses))
		 // $responses{$i} is one "bytes from ..." or "Request timeout ..." line
	End for 
End if 
```

# Initial Setup

The Zig command line is relatively easy to use in the single file version

```
zigdnsguide % zig version
0.13.0
zigdnsguide % zig help
Usage: zig [command] [options]

Commands:

  -- snip -- 
  test             Perform unit testing
  run              Create executable and run immediately

  -- snip --
  version          Print version number and exit
  zen              Print Zen of Zig and exit

General Options:

  -h, --help       Print command-specific usage
```

While the zig command itself is relatively powerful, this guide doesn’t delve into any of the build tool functions provided by it. `zig test` and `zig run` are going to be the two main versions of the command that it uses, and I often use them like this: 

```
zigdnsguide % zig test src/main.zig && zig run src/main.zig
```

Which basically runs the unit tests before running the application.

## Getting the Test Data

Emil’s guide uses `netcat` or `nc` to collect some DNS packets. I’ve reproduced the commands here because I frequently used them to test the results of my code vs talking to real DNS servers.

```
zigdnsguide % nc -u -l 1053 > query_packet.txt
```

Quick breakdown of the options for reuse later:
* `-u` means to use datagrams / udp
* `-l 1053` means to listen on a specific port. 53 is default for DNS. We’re over 1024 here to avoid privilege escalation
* `> query_packet.txt` means to (truncate) and write the bytes to the file `query_packet`.

This is being used to capture the DNS query packet that `dig` is going to send.

```
zigdnsguide % dig +retry=0 -p 1053 @127.0.0.1 +noedns google.com
```

Quick breakdown of the options here:
* `+retry=0` means don’t retry. The goal is to capture a single packet.
* `-p 1053` means to use port on the DNS server
* `@127.0.0.1` means to use the host `127.0.0.1` for the DNS server.
* `+noedns` clears the EDNS version sent to the server (basically defaulting it to zero) to keep the packet simple. Check out [RFC6891](https://datatracker.ietf.org/doc/html/rfc6891) for more details.
* `google.com` is the name to lookup.

Once the DNS query packet is captured, it gets sent to a real DNS server, in order to see what the response is supposed to look like. I used this command a lot in order to compare the results of my server to the results of real servers:

```
zigdnsguide % nc -u 8.8.8.8 53 < query_packet.txt > response_packet.txt
```

Again
* `-u` means to use UDP.
* `8.8.8.8` means to use google’s publicly provided DNS resolver.
* `53` means to use the standard DNS port.
* `< query_packet.txt` means to read the bytes to send from the file `query_packet.txt`
* `> response_packet.txt` means to write the bytes received to the file `response_packet.txt`

I also found it useful to have a good hex viewer, to look at and compare my results. The biggest challenge I had was that the TTLs from servers are not always consistent, so it was necessary to understand enough of the packet to know where values normally change between calls and where my server was writing an incorrect byte.

## Create src/main.zig

This tutorial doesn’t get into the zig build system, but it is worth touching on this one point. The `zig init` command will place all of the source files under `./src`. To make it easier to add a build tutorial later, I decided to keep all the source files under the same structure.

I created the file `./src/main.zig`, and filled it with the following code:

```zig
const std = @import("std");

pub fn main() !void {
    std.debug.print("Hello, {s} number {d}\n", .{ "zig", 1 });
}

test "simple test" {
    const expect: u32 = 5;
    const actual: u32 = 4 + 3;
    try std.testing.expectEqual(expect, actual);
}
```

Before I jump into the code for this chapter, I think it makes sense to call out the way Zig does testing.

Testing in Zig is very baked into the language. Tests can be placed pretty much anywhere and the [zig.guide](https://zig.guide/getting-started/running-tests) uses these tests instead of using mock programs.

For the lower level components, I provide unit tests.

```
zigdnsguide % zig test src/main.zig
expected 5, found 7
1/1 main.test.simple test...FAIL (TestExpectedEqual)
-- snip --
```

The test failed; the expected 5 is not the same as the actual 7. Once I fixed the value of actual, and re-run the command it should now show that all the tests pass.

```
zigdnsguide % zig test src/main.zig
All 1 tests passed.
```

The main function can be invoked as well:

```
zigdnsguide % zig run src/main.zig
Hello, zig number 1
```

## Conclusion

With that out of the way, it’s time to jump into the main parts of the guide. Let’s move on to [Chapter 1](./Chapter01.md).
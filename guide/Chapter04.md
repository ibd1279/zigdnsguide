# Baby’s first DNS Server

[Emil’s guide](https://github.com/EmilHernvall/dnsguide/blob/master/chapter4.md) explains the break down of DNS servers and authorities. We’re not going to repeat all those details. Instead, we will jump right into the code changes.

## Moving the Lookup Logic

The logic here is a bit more verbose than Emil’s, although most of this is because Zig isn’t offering a developer friendly interface on top of the posix interface. We do add an address parameter that Emil didn’t pass. That will become more useful in the next chapter.

```zig
fn lookup(alloc: std.mem.Allocator, qname: []const u8, qtype: QueryType, server: std.net.Address) !Packet {
    const socket = try std.posix.socket(server.any.family, std.posix.SOCK.DGRAM, 0);
    defer std.posix.close(socket);
    try std.posix.connect(socket, &server.any, server.getOsSockLen());

    var packet = Packet.init(alloc);
    defer packet.deinit();
    packet.header.id = 6666;
    packet.header.recursion_desired = true;

    // Perform an A query for google.com
    try packet.appendQuestion(qname, qtype);

    var req_buffer = BytePacketBuffer.init(alloc);
    defer req_buffer.deinit();

    try packet.write(&req_buffer);
    const bytes = req_buffer.buf[0..req_buffer.pos];
    _ = try std.posix.send(socket, bytes, 0);

    var res_buffer = BytePacketBuffer.init(alloc);
    defer res_buffer.deinit();
    _ = try std.posix.recv(socket, res_buffer.buf[0..], 0);

    return try Packet.read(alloc, &res_buffer);
}
```

## Implementing our first server

Now that we have a way to look up any address, we need to create the logic that receives the packet from the client, and calls our lookup function.

```zig
fn handleQuery(alloc: std.mem.Allocator, socket: std.posix.socket_t) !void {
    // With a socket ready, we can go ahead and read a packet. This will
    // block until one is received.
    var req_buffer = BytePacketBuffer.init(alloc);
    defer req_buffer.deinit();

    // The `recv_from` function will write the data into the provided buffer,
    // and return the length of the data read as well as the source address.
    // We're not interested in the length, but we need to keep track of the
    // source in order to send our reply later on.
    var client_address: std.posix.sockaddr = undefined;
    var client_address_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
    _ = try std.posix.recvfrom(socket, req_buffer.buf[0..], 0, &client_address, &client_address_len);

    // Next, `DnsPacket::read` is used to parse the raw bytes into
    // a `DnsPacket`.
    var request = try Packet.read(alloc, &req_buffer);
    defer request.deinit();

    // Create and initialize the response packet
    var packet = Packet.init(alloc);
    defer packet.deinit();
    packet.header.id = request.header.id;
    packet.header.recursion_desired = true;
    packet.header.recursion_available = true;
    packet.header.response = true;

    // In the normal case, exactly one question is present
    if (request.questions.popOrNull()) |question| {
        std.debug.print("Received query: {}\n", .{question});

        // Since all is set up and as expected, the query can be forwarded to the
        // target server. There's always the possibility that the query will
        // fail, in which case the `SERVFAIL` response code is set to indicate
        // as much to the client. If rather everything goes as planned, the
        // question and response records as copied into our response packet.
        const server = try std.net.Address.resolveIp("8.8.8.8", 53);
        if (lookup(alloc, question.qname, question.qtype, server)) |result| {
            try packet.questions.append(question);
            packet.header.rescode = result.header.rescode;

            for (result.answers.items) |rec| {
                std.debug.print("Answer: {}\n", .{rec});
                try packet.answers.append(rec);
            }
            for (result.authorities.items) |rec| {
                std.debug.print("Authority: {}\n", .{rec});
                try packet.authorities.append(rec);
            }
            for (result.resources.items) |rec| {
                std.debug.print("Resource: {}\n", .{rec});
                try packet.resources.append(rec);
            }
        } else |err| {
            std.debug.print("unable to lookup: {}", .{err});
            packet.header.rescode = ResultCode.form_err;
        }
    }
    // Being mindful of how unreliable input data from arbitrary senders can be, we
    // need make sure that a question is actually present. If not, we return `FORMERR`
    // to indicate that the sender made something wrong.
    else {
        packet.header.rescode = ResultCode.form_err;
    }

    var res_buffer = BytePacketBuffer.init(alloc);
    defer res_buffer.deinit();

    try packet.write(&res_buffer);
    const len = res_buffer.pos;
    const data = try res_buffer.getRange(0, len);
    _ = try std.posix.sendto(socket, data, 0, &client_address, client_address_len);
}
```

The main interesting things here are the `recvfrom` and the `sendto` which are [standard posix functions](https://pubs.opengroup.org/onlinepubs/9699919799.2016edition/basedefs/sys_socket.h.html). These allow a UDP server to reply to multiple different clients while listening on the same port.

The last thing that we need to do is replace the main function so that it listens on a port rather than executing a lookup:

```zig
pub fn main() !void {
    // get our allocator
    var gpa = std.heap.GeneralPurposeAllocator(std.heap.GeneralPurposeAllocatorConfig{}){};
    const alloc = gpa.allocator();

    const address = try std.net.Address.resolveIp("0.0.0.0", 2053);
    const socket = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
    try std.posix.bind(socket, &address.any, address.getOsSockLen());

    while (true) {
        handleQuery(alloc, socket) catch |err| {
            std.debug.print("An error occured: {}\n", .{err});
        };
    }
}
```

We’ll start the service running in one terminal window, and then run the following dig command to test things out:

```
dig @localhost -p 2053 yahoo.com
```

The dig command should execute successfully, and we will see something like the following as output from our service:

```
zigdnsguide % zig run src/main.zig
Received query: yahoo.com. IN a
Answer: yahoo.com. 335 IN a 98.137.11.163:0
Answer: yahoo.com. 335 IN a 74.6.231.21:0
Answer: yahoo.com. 335 IN a 74.6.143.25:0
Answer: yahoo.com. 335 IN a 74.6.231.20:0
Answer: yahoo.com. 335 IN a 74.6.143.26:0
Answer: yahoo.com. 335 IN a 98.137.11.164:0
```

## Conclusion

This was a short chapter, and didn’t involve many changes beyond moving code around that we had already written. But that’s fine, because now we have a working DNS proxy server. In the next chapter, we’ll add break our dependency on `8.8.8.8` as we implement a recursive resolve. 
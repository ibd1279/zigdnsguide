# Building a stub resolver in Zig

Now that we can read a dns message, it is time to create a query and send it somewhere. This is all based on [Emil’s dnsguide](https://github.com/EmilHernvall/dnsguide/blob/master/chapter2.md). But first, we have to make some changes to the previous chapters code.

One of the interesting contributions of Rust is making lifetime relationships explicit. Zig doesn’t include them in the type system, but that doesn’t mean that we don’t have to think about them. Before we can get to writing packets, we need to change the lifetime relationships between the `BytePacketBuffer` and the `Packet`.

## Allocators and Deciding Who Cleans Up

Memory management in Zig hews very close to the C philosophy, where alloc/free of the memory are completely divorced from the init/destroy of the object, and the lifetime relationship is up to the developer to engineer.

There is no global allocator in Zig, and a lot of functions expect to receive an [`Allocator`](https://zig.guide/standard-library/allocators) as part of their signature or as part of their initialization. We’ve seen examples of this with the `ArrayList` fields of `Packet` and in the tests we’ve written.

In the first chapter, we used the `LabelIterator` as the name fields of `Question` and `Record`. That was fine when the data was stored in the buffer, but now we need the name *before* it is written in the buffer. Something needs to be responsible for the string memory before it gets written to the buffer.

We’re going to make the Packet responsible for the lifetimes, since it controls the lifespan of the `ArrayList` where the objects live. It also already has an allocator reference.

First up is updating `Question`. Presenting the whole structure here for simplicity in updating.

```zig
/// Question
const Question = struct {
    qname: []u8,
    qtype: QueryType,
    qclass: u16, // always 1 for IN.

    // release the mory used by the qname.
    fn deinit(self: *const Question, alloc: std.mem.Allocator) void {
        alloc.free(self.qname);
    }

    fn read(alloc: std.mem.Allocator, buffer: *BytePacketBuffer) !Question {
        const qname = try buffer.readLabelIterator();
        const qtype = QueryType.fromNum(try buffer.readU16());
        const qclass = try buffer.readU16(); // Read the class from the buffer.

        // Copy the string to newly allocated memory.
        var name_list = std.ArrayList(u8).init(alloc);
        defer name_list.deinit();
        try qname.toFqdn(name_list.writer());
        const slice = try name_list.toOwnedSlice();

        return .{
            .qname = slice,
            .qtype = qtype,
            .qclass = qclass,
        };
    }

    pub fn format(
        self: Question,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        // blind reads so the compiler doesn't complain about unused parameters.
        _ = fmt;
        _ = options;

        try writer.print("{s} IN {s}", .{ self.qname, @tagName(self.qtype) });
    }
};
```

We’ve basically moved some of the serialization lines from `format()` to  `read()` , and added a `deinit()` method.

We’re going to do the same-thing with the `Record` type:

```zig
/// Record is the common preamble at the start of all records.
/// I broke it into a different class to reduce the amount of code duplication.
const Record = struct {
    name: []u8,
    rtype: u16,
    class: u16, // always 1 for IN.
    ttl: u32,
    data_len: u16,
    data: RecordData,

    // release the mory used by the name.
    fn deinit(self: *const Record, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
    }

    fn read(alloc: std.mem.Allocator, buffer: *BytePacketBuffer) !Record {
        const name = try buffer.readLabelIterator();
        const rtype = try buffer.readU16();
        const class = try buffer.readU16(); // Class is always 1
        const ttl = try buffer.readU32();
        const data_len = try buffer.readU16();
        const data = try RecordData.read(rtype, data_len, buffer);

        // Copy the string to newly allocated memory.
        var name_list = std.ArrayList(u8).init(alloc);
        defer name_list.deinit();
        try name.toFqdn(name_list.writer());
        const slice = try name_list.toOwnedSlice();

        return Record{
            .name = slice,
            .rtype = rtype,
            .class = class,
            .ttl = ttl,
            .data_len = data_len,
            .data = data,
        };
    }

    pub fn format(
        self: Record,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        // blind reads so the compiler doesn't complain about unused parameters.
        _ = fmt;
        _ = options;

        try writer.print("{s} {d} IN {s} {}", .{ self.name, self.ttl, @tagName(self.data), self.data });
    }
};
```

Once those are done, we have to update the `Packet` type to release the memory and share the allocator.

```zig
const Packet = struct {

		-- snip --

    fn deinit(self: *Packet) void {
        for (self.questions.items) |rec| {
            rec.deinit(self.allocator);
        }
        self.questions.deinit();

        for (self.answers.items) |rec| {
            rec.deinit(self.allocator);
        }
        self.answers.deinit();

        for (self.authorities.items) |rec| {
            rec.deinit(self.allocator);
        }
        self.authorities.deinit();

        for (self.resources.items) |rec| {
            rec.deinit(self.allocator);
        }
        self.resources.deinit();
    }

    fn read(alloc: std.mem.Allocator, buffer: *BytePacketBuffer) !Packet {
        var packet = Packet.init(alloc);
        errdefer packet.deinit();

        packet.header = try Header.read(buffer);

        try packet.questions.ensureTotalCapacityPrecise(packet.header.question_entries);
        for (0..packet.header.question_entries) |_| {
            try packet.questions.append(try Question.read(packet.allocator, buffer));
        }
        try packet.answers.ensureTotalCapacityPrecise(packet.header.answer_entries);
        for (0..packet.header.answer_entries) |_| {
            try packet.answers.append(try Record.read(packet.allocator, buffer));
        }
        try packet.authorities.ensureTotalCapacityPrecise(packet.header.authoritative_entries);
        for (0..packet.header.authoritative_entries) |_| {
            try packet.authorities.append(try Record.read(packet.allocator, buffer));
        }
        try packet.resources.ensureTotalCapacityPrecise(packet.header.resource_entires);
        for (0..packet.header.resource_entires) |_| {
            try packet.resources.append(try Record.read(packet.allocator, buffer));
        }

        return packet;
    }
};
```

We can re run the program again, and it will look the same, but we’ve accomplished two things. The first is that we disconnected the lifetime of the `Packet` from the lifetime of the `BytePacketBuffer`, which allows us to allocate the buffer on the stack while returning the packet. The second is that we can now create packets without a buffer.

## Writing Bytes

The first thing we need to be able to do is craft our question packet that we want to send. We start again with the `BytePacketBuffer`, and add the writing methods.

```zig
const BytePacketBuffer = struct {

		-- snip --

    /// Write a single byte.
    fn write(self: *BytePacketBuffer, val: u8) !void {
        if (self.pos >= udp_packet_max) {
            return BufferError.BeyondEnd;
        }
        self.buf[self.pos] = val;
        try self.step(1);
    }

    // Set a single byte at a specific location
    fn set(self: *BytePacketBuffer, pos: usize, val: u8) !void {
        if (pos >= udp_packet_max) {
            return BufferError.BeyondEnd;
        }
        self.buf[pos] = val;
    }

    /// Write a u16
    fn writeU16(self: *BytePacketBuffer, short: u16) !void {
        try self.write(@truncate(short >> 8));
        try self.write(@truncate(short));
    }

    // Write a u32
    fn writeU32(self: *BytePacketBuffer, val: u32) !void {
        try self.write(@truncate(val >> 24));
        try self.write(@truncate(val >> 16));
        try self.write(@truncate(val >> 8));
        try self.write(@truncate(val));
    }

    // Set a two bytes at a specific location.
    fn setU16(self: *BytePacketBuffer, pos: usize, short: u16) !void {
        try self.set(pos, @truncate(short >> 8));
        try self.set(pos + 1, @truncate(short & 0xFF));
    }

    fn writeName(self: *BytePacketBuffer, qname: []const u8) !void {
        var iter = std.mem.splitScalar(u8, qname, '.');
        while (iter.next()) |label| {
            const len = label.len;
            if (len > 0x3F) {
                return BufferError.LabelLengthExceeded;
            } else if (len == 0) {
                break;
            }
            try self.write(@truncate(len));
            for (label) |c| {
                try self.write(c);
            }
        }
        try self.write(0);
    }
};
```

Again, nothing special other than hand converting `hton`.  Adding a test as usual. According to the DNS spec two consecutive dots (`..`) are not allowed in a name, which is why we have the `break` when the label length is `0`.

```zig
test "BytePackteBuffer write testing" {
    const alloc = std.testing.allocator;
    var buffer = BytePacketBuffer{};
    for (&buffer.buf, 0..) |*byte, i| {
        byte.* = @truncate(i & 0xFF);
    }

    var pos = buffer.pos;
    const expect8: u8 = 0xFF;
    try buffer.write(expect8);
    try std.testing.expectEqual(expect8, buffer.get(pos));
    try buffer.set(pos + 10, expect8);
    try std.testing.expectEqual(expect8, buffer.get(pos + 10));

    pos = buffer.pos;
    const expect16: u16 = 0xCABE;
    try buffer.writeU16(expect16);
    try std.testing.expectEqual(expect16 >> 8, buffer.buf[pos]);
    try std.testing.expectEqual(expect16 & 0xFF, buffer.buf[pos + 1]);
    try buffer.setU16(pos + 10, expect16);
    try std.testing.expectEqual(expect16 >> 8, buffer.buf[pos + 10]);
    try std.testing.expectEqual(expect16 & 0xFF, buffer.buf[pos + 11]);

    pos = buffer.pos;
    const expect32: u32 = 0x1337BABE;
    try buffer.writeU32(expect32);
    try std.testing.expectEqual((expect32 >> 24) & 0xFF, buffer.buf[pos]);
    try std.testing.expectEqual((expect32 >> 16) & 0xFF, buffer.buf[pos + 1]);
    try std.testing.expectEqual((expect32 >> 8) & 0xFF, buffer.buf[pos + 2]);
    try std.testing.expectEqual(expect32 & 0xFF, buffer.buf[pos + 3]);

    pos = buffer.pos;
    const expectSimpleFqdn = "shaken.and.stirred.drink.bar.internal.";
    try buffer.writeName(expectSimpleFqdn);
    try buffer.seek(pos);
    var chain1 = try buffer.readLabelIterator();
    var result1 = std.ArrayList(u8).init(alloc);
    defer result1.deinit();
    try chain1.toFqdn(result1.writer());
    try std.testing.expectEqualStrings(expectSimpleFqdn, result1.items);
}
```

## DNS Header

Similar to reading the header, writing the DNS header is a bunch of bit manipulation. We’re aren’t doing much interesting

```zig
const Header = struct {

		-- snip --
		
    pub fn write(self: *const Header, buffer: *BytePacketBuffer) !void {
        try buffer.writeU16(self.id);

        const recursion_desired: u8 = @intFromBool(self.recursion_desired);
        const truncated_message: u8 = @intFromBool(self.truncated_message);
        const authoritative_answer: u8 = @intFromBool(self.authoritative_answer);
        const opcode: u8 = @intFromEnum(self.opcode);
        const response: u8 = @intFromBool(self.response);
        try buffer.write(recursion_desired | (truncated_message << 1) | (authoritative_answer << 2) | (opcode << 3) | (response << 7));

        const rescode: u8 = @intFromEnum(self.rescode);
        const checking_disabled: u8 = @intFromBool(self.checking_disabled);
        const authed_data: u8 = @intFromBool(self.authed_data);
        const z: u8 = @intFromBool(self.z);
        const recursion_available: u8 = @intFromBool(self.recursion_available);
        try buffer.write(rescode | (checking_disabled << 4) | (authed_data << 5) | (z << 6) | (recursion_available << 7));

        try buffer.writeU16(self.question_entries);
        try buffer.writeU16(self.answer_entries);
        try buffer.writeU16(self.authoritative_entries);
        try buffer.writeU16(self.resource_entires);
    }
		
		-- snip --
		
};
```

## Question
‌
Writing the question is very straightforward, because it always has the same structure.

```zig
const Question = struct {

		-- snip --

    fn write(self: *const Question, buffer: *BytePacketBuffer) !void {
        try buffer.writeName(self.qname);
        try buffer.writeU16(@intFromEnum(self.qtype));
        try buffer.writeU16(self.qclass);
    }

		-- snip --

};
```

## Record and RecordData

The `Record` structure is the same as the above additions, but `RecordData` will be a bit more interesting.

```zig
const Record = struct {

		-- snip --

    fn write(self: *const Record, buffer: *BytePacketBuffer) !void {
        try buffer.writeName(self.name);
        try buffer.writeU16(self.rtype);
        try buffer.writeU16(self.class);
        try buffer.writeU32(self.ttl);
        const size_pos = buffer.pos;
        try buffer.writeU16(self.data_len);
        try self.data.write(buffer);

        // I'd rather be accurate to what was written than to what was
        // on the structure.
        try buffer.setU16(size_pos, @truncate(buffer.pos - size_pos));
    }

		-- snip --

};
```

For record data, it looks like the reverse of the read method, with a big switch to get around the static dispatch.

```zig
const RecordData = union(QueryType) {

		-- snip --

    pub fn write(self: *const RecordData, buffer: *BytePacketBuffer) !void {
        switch (self.*) {
            .a => |r| {
                const octets = @as(*const [4]u8, @ptrCast(&r.addr.sa.addr));
                try buffer.write(octets[0]);
                try buffer.write(octets[1]);
                try buffer.write(octets[2]);
                try buffer.write(octets[3]);
            },
            .unknown => |r| {
                // Skipping the unknown records for now but this will mess up the header counts.
                std.debug.print("Skipping records: {}\n", .{r});
            },
        }
    }

		-- snip --

};
```

## Packet

We’re almost done with the boilerplate, but we have to finish with packet. We will add two methods here. The first is another write function. The second is a helper method to add questions to a packet.

```zig
const Packet = struct {

		-- snip --

    fn write(self: *const Packet, buffer: *BytePacketBuffer) !void {
        var stack_header = self.header;

        stack_header.question_entries = @truncate(self.questions.items.len);
        stack_header.answer_entries = @truncate(self.answers.items.len);
        stack_header.authoritative_entries = @truncate(self.authorities.items.len);
        stack_header.resource_entires = @truncate(self.resources.items.len);

        try stack_header.write(buffer);
        for (self.questions.items) |q| {
            try q.write(buffer);
        }
        for (self.answers.items) |r| {
            try r.write(buffer);
        }
        for (self.authorities.items) |r| {
            try r.write(buffer);
        }
        for (self.resources.items) |r| {
            try r.write(buffer);
        }
    }

    fn appendQuestion(self: *Packet, qname: []const u8, qtype: QueryType) !void {
        const name = try self.allocator.alloc(u8, qname.len);
        errdefer self.allocator.free(name);
        @memcpy(name, qname);
        try self.questions.append(Question{
            .qname = name,
            .qtype = qtype,
            .qclass = 1,
        });
        self.header.question_entries += 1;
    }
};
```

We added the helper function to make a version of the string that `Packet` owns. This is the main reason we had to switch from the `LabelIterator` at the start of the chapter.

## Socket Programming 101

The Zig standard library supports sockets, but as far as I could tell it does nothing to hide all the rough edges of the [posix socket programming](https://ziglang.org/documentation/master/std/#std.posix).

We’re going to replace the whole main function with the following:

```zig
pub fn main() !void {
    // get our allocator
    var gpa = std.heap.GeneralPurposeAllocator(std.heap.GeneralPurposeAllocatorConfig{}){};
    const alloc = gpa.allocator();

    // Perform an A query for google.com
    const qname = "google.com";
    const qtype = QueryType.a;

    // Using googles public DNS server
    const server = try std.net.Address.resolveIp("8.8.8.8", 53);

    // Bind a UDP socket to an arbitrary port
    const socket = try std.posix.socket(server.any.family, std.posix.SOCK.DGRAM, 0);
    defer std.posix.close(socket);
    try std.posix.connect(socket, &server.any, server.getOsSockLen());

    // Build our query packet. It's important that we remember to set the
    // `recursion_desired` flag. As noted earlier, the packet id is arbitrary.
    var packet = Packet.init(alloc);
    defer packet.deinit();
    packet.header.id = 6666;
    packet.header.recursion_desired = true;
    try packet.appendQuestion(qname, qtype);

    std.debug.print("Header: {any}\n", .{packet.header});

    for (packet.questions.items) |rec| {
        std.debug.print("Question: {}\n", .{rec});
    }
    for (packet.answers.items) |rec| {
        std.debug.print("Answer: {}\n", .{rec});
    }
    for (packet.authorities.items) |rec| {
        std.debug.print("Authority: {}\n", .{rec});
    }
    for (packet.resources.items) |rec| {
        std.debug.print("Resource: {}\n", .{rec});
    }

    // Use our new write method to write the packet to a buffer...
    var req_buffer = BytePacketBuffer{};
    try packet.write(&req_buffer);

    // ...and send it off to the server using our socket:
    _ = try std.posix.send(socket, req_buffer.buf[0..req_buffer.pos], 0);

    // To prepare for receiving the response, we'll create a new `BytePacketBuffer`,
    // and ask the socket to write the response directly into our buffer.
    var res_buffer = BytePacketBuffer{};
    _ = try std.posix.recv(socket, res_buffer.buf[0..], 0);

    // As per the previous section, `DnsPacket::from_buffer()` is then used to
    // actually parse the packet after which we can print the response.
    var res_packet = try Packet.read(alloc, &res_buffer);
    defer res_packet.deinit();

    std.debug.print("Header: {any}\n", .{res_packet.header});

    for (res_packet.questions.items) |rec| {
        std.debug.print("Question: {}\n", .{rec});
    }
    for (res_packet.answers.items) |rec| {
        std.debug.print("Answer: {}\n", .{rec});
    }
    for (res_packet.authorities.items) |rec| {
        std.debug.print("Authority: {}\n", .{rec});
    }
    for (res_packet.resources.items) |rec| {
        std.debug.print("Resource: {}\n", .{rec});
    }
}
```

There is a lot of code there, but most of it is outputting the query and the answer packets. We’ve already seen some of the [std.net.Address](https://ziglang.org/documentation/master/std/#std.net.Address) stuff in the `A` record, but here we use an IPv6 compatible method because we may traverse IPv6 in later chapters. Also, unlike `A` and `AAAA` records, we don’t know or care which type of address this is.

This has an affect on the Socket creation as well:

```
    const socket = try std.posix.socket(server.any.family, std.posix.SOCK.DGRAM, 0);
    defer std.posix.close(socket);
    try std.posix.connect(socket, &server.any, server.getOsSockLen());
```

We use the `server.any` tag on the enum, rather than the `in` or `in6` tags, because we don’t know which one it is. We also let the address dictate the family, since we don’t know if it is `INET` or `INET6`.

## The Output

We’ve now implemented a DNS client, or a stub resolver. When we run the program, we get the following output.

```
zigdnsguide % zig run src/main.zig
Header: opcode: main.OpCode.query, status: main.ResultCode.no_error, id: 6666, flags: rd; QUERY: 1, ANSWER: 0, AUTHORITY: 0, ADDITIONAL: 0
Question: google.com IN a
Header: opcode: main.OpCode.query, status: main.ResultCode.no_error, id: 6666, flags: qr rd ra; QUERY: 1, ANSWER: 1, AUTHORITY: 0, ADDITIONAL: 0
Question: google.com. IN a
Answer: google.com. 256 IN a 142.250.179.78:0
```

We can now move on to [Chapter 3](./Chapter03.md), where we add more types to the `RecordData` tagged union. We’ll also implement a simple trie to support writing names that jump around.

[Full source](../src/chapter02.zig) of this chapter.
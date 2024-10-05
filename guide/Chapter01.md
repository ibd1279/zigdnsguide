# Reading DNS Data and Zig’s Result

In this first chapter, we’ll allocate some space on the stack, read our bytes, and be able to display them. I tried to avoid allocating any memory in this part of the tutorial, but that does mean we will be changing how we handle some of the query names in later chapters (zigs handling of strings is positively C-like).

> Disclaimer: I’m new to Zig myself, so I’m open for conversations on if this is really the most “correct” or “idiomatic”  way to write Zig.

## Chapter 1 - The DNS Protocol

Go read [Emil’s dnsguide](https://github.com/EmilHernvall/dnsguide/blob/master/chapter1.md). I’m not going to cover all the DNS details he does. While you don’t have to be an expert on DNS, knowing the requirements and the schema of the packet will come in handy as this chapter is all about the wire format.

### BufferError

Now that we know about how the bytes are arranged on the wire protocol, the first thing to do is build a class that manages all that wire format business for us. The structure here isn’t ver complicated, but it does get into the basics of creating a structure, adding some methods, and testing them. Replace the entire `src/main.zig` with the following:

```zig
const std = @import("std");

/// BufferError us used by the BytePacketBuffer for any errors.
/// Zig uses the bang (!) to denote a function **may** return an error.
const BufferError = error{
    BeyondEnd,
    TooManyJumps,
    LabelLengthExceeded,
};
```

We’ve created our first error type to handle when we try to read past the end of the buffer, a name tries to jump too many times, and when the length of a label is too long for the dns encoding. We aren’t going to do much direct error handling for this guide, but similar to how `Result<T>` is all over the place in Rust, error handling will be all over the place in Zig.

There are three ways to deal with errors in Zig: `catch`, `try` and `if`. The [zig.guide](https://zig.guide/language-basics/errors) provides a good overall explanation of the concepts, but the main thing we’re going to use is `try` in functions that return an error tuple.

## BytePacketBuffer

After the BufferError, add the following code:

```zig
/// BytePacketBuffer encapsulates all the logic for buffering all the
/// reading and writing of the udp packets.
const BytePacketBuffer = struct {
    buf: [udp_packet_max]u8 = undefined,
    pos: usize = 0,

    /// Maximum length of a udp packet
    /// Zig doesn't have the traditional "static" concepts, but this gets close.
    const udp_packet_max = 512;

    /// Empty the buffer.
    fn reset(self: *BytePacketBuffer) void {
        @memset(&self.buf, 0);
        self.pos = 0;
    }

    /// Step the buffer position forward a specific number of steps
    /// The bang in the return type means that this method will either
    /// return an error or return void.
    ///
    /// You can think of the bang as being similar to a rust `Result<>`. In
    /// most cases it is best to let the compilier figure out the possible
    /// error types rather than be explicit about them.
    fn step(self: *BytePacketBuffer, steps: usize) !void {
        if (self.pos + steps >= udp_packet_max) {
            return BufferError.BeyondEnd;
        }
        self.pos += steps;
    }

    /// Change the buffer position
    fn seek(self: *BytePacketBuffer, loc: usize) !void {
        if (loc >= udp_packet_max) {
            return BufferError.BeyondEnd;
        }
        self.pos = loc;
    }

    /// Read a single byte and move the position one step forward
    fn read(self: *BytePacketBuffer) !u8 {
        if (self.pos >= udp_packet_max) {
            return BufferError.BeyondEnd;
        }
        const res = self.buf[self.pos];
        self.pos += 1;

        return res;
    }

    /// Get a single byte, without changing the buffer position
    fn get(self: *const BytePacketBuffer, loc: usize) !u8 {
        if (loc >= udp_packet_max) {
            return BufferError.BeyondEnd;
        }
        return self.buf[loc];
    }

    /// Read the bytes of a range. Returns a slice referencing the underlying data.
    fn getRange(self: *const BytePacketBuffer, loc: usize, len: usize) ![]const u8 {
        if (loc + len >= udp_packet_max) {
            return BufferError.BeyondEnd;
        }
        return self.buf[loc .. loc + len];
    }
};
```

These are all of the base functions for reading data from the buffer. Each one is returning an error tuple, as denoted by the return types that start with a bang (`!`). Zig is able to automatically figure out if the intent is to return an error (`return BufferError.BeyondEnd`) or a value (`return res`).

Now we can add a test to the end of the file to start “handling” the error tuples:

```zig

test "BytePacketBuffer basics testing" {
    var buffer = BytePacketBuffer{};

    // test that init zero's things
    buffer.reset();
    for (buffer.buf) |byte| {
        try std.testing.expect(byte == 0);
    }

    try std.testing.expect(buffer.seek(BytePacketBuffer.udp_packet_max) == BufferError.BeyondEnd);
    try buffer.seek(BytePacketBuffer.udp_packet_max - 2);
    try buffer.step(1);
    try std.testing.expect(buffer.step(1) == BufferError.BeyondEnd);

    buffer.reset();
    for (&buffer.buf, 0..) |*byte, i| {
        byte.* = @truncate(i & 0xFF);
    }
    try std.testing.expect(try buffer.get(8) == 8);
    try buffer.step(9);
    try std.testing.expect(try buffer.read() == 9);
    try std.testing.expect(try buffer.read() == 10);

    const default_range = [_]u8{ 0, 0 };
    const range = buffer.getRange(20, 2) catch default_range[0..];
    for (range, 20..) |byte, i| {
        std.testing.expect(byte == i) catch |err| {
            return err;
        };
    }
}
``` 

We see `try` all over the place, and it obviously isn’t being used like `try/catch` in Java. We have a couple of examples to demonstrate `catch` at the end of the tests. The first uses `catch` as on expression to provide a default value. The second uses `catch` as a control structure, to demonstrate what all the other `try` statements are doing. We’ll have an example of the `if` usage later.

The main take away is that `try` is very similar to how `?` is used in Rust. We can run these tests, and everything should pass.

With the basics out of the way, we can add the integer read helper functions, and some tests for them.

```zig
const BytePacketBuffer = struct {

		-- snip --

    /// Read two bytes, advancing forward two steps.
    fn readU16(self: *BytePacketBuffer) !u16 {
        const upper: u16 = try self.read();
        const lower: u16 = try self.read();
        return (upper << 8) | lower;
    }

    /// Read four bytes, advancing forward four steps.
    fn readU32(self: *BytePacketBuffer) !u32 {
        const upup: u32 = try self.read();
        const up: u32 = try self.read();
        const low: u32 = try self.read();
        const lowlow: u32 = try self.read();
        return (upup << 24) | (up << 16) | (low << 8) | lowlow;
    }
};
```

And

```zig
test "BytePacketBuffer read testing" {
    var buffer = BytePacketBuffer{};
    for (&buffer.buf, 0..) |*byte, i| {
        byte.* = @truncate(i & 0xFF);
    }

    // Integer reads
    try buffer.seek(1);
    try std.testing.expect(try buffer.readU16() == 0x0102);
    try std.testing.expect(try buffer.readU32() == 0x03040506);
}
```

That part wasn’t very advanced. The reality is that we should probably do some `hton/ntoh` translations here, but this follows exactly with how [Emil’s code](https://github.com/EmilHernvall/dnsguide/blob/master/chapter1.md) approached it. 

## Reading Names from the Buffer

The advanced part is actually this next part, which has to do with how strings are encoded into a DNS packet, and I call the concept a `LabelIterator`.

We’re going to use a `LabelIterator` mostly to avoid allocating memory for a string right now. Add the following, new structure **inside** the `BytePacketBuffer` structure, near the bottom:

```zig
const BytePacketBuffer = struct {

		-- snip --

    /// LabelIterator follows a chain of labels inside a DNS Packet. Since a name inside
    /// a DNS packet can jump around to already defined labels, this allows for
    /// consuming the label chunks in order without copying the bytes out of the
    /// BytePacketBuffer, avoiding an allocation for reading.
    const LabelIterator = struct {
        buffer: *const BytePacketBuffer,
        pos: usize,
        jump_count: u8,

        /// maximum number of jumps before we stop jumping around.
        const max_jumps: u8 = 5;

        /// delimiter between labels
        const delimiter: u8 = '.';

        /// Create a new LabelChain that starts at the provided location
        /// inside the byte buffer.
        ///
        /// This does not take ownership of any memeory.
        fn init(buf: *const BytePacketBuffer, pos: usize) LabelIterator {
            return .{
                .buffer = buf,
                .pos = pos,
                .jump_count = 0,
            };
        }

        /// Get the next label from the Iterator. Returns null once the chain is
        /// exhausted. Call `reset()` to start the chain over again.
        pub fn next(self: *LabelIterator) ?[]const u8 {
            const length: u16 = self.buffer.get(self.pos) catch return null;
            if (length == 0) {
                return null;
            } else if (length & 0xC0 == 0xC0) {
                if (self.jump_count > max_jumps) {
                    return null;
                }
                const lower: u16 = self.buffer.get(self.pos + 1) catch return null;
                const offset = ((length ^ 0xC0) << 8) | lower;
                self.pos = @intCast(offset);
                return self.next();
            }
            const start = self.pos + 1;
            self.pos = start + length;
            return self.buffer.getRange(start, length) catch return null;
        }

        /// toFqdn writes all the labels, separated by the delimiter, to
        /// the provided writer.
        fn toFqdn(self: LabelIterator, writer: anytype) !void {
            var mut_self = self;
            while (mut_self.next()) |label| {
                try writer.print("{s}{c}", .{ label, delimiter });
            }
        }
    };

    /// Read a qname
    fn readLabelIterator(self: *BytePacketBuffer) !LabelIterator {
        // Create the label iterator, then we step past it.
        const iter = LabelIterator.init(self, self.pos);

        // qnames can jump around, need to keep state as we go.
        var loc = self.pos;

        while (true) {
            // At this point, we're always at the beginning of a label. Recall
            // that labels start with a length byte.
            const len: u16 = try self.get(loc);

            // If len has the two most significant bit are set, it represents a
            // jump to some other offset in the packet:
            if (len & 0xC0 == 0xC0) {
                loc += 2;
                break;
            }

            // Move a single byte forward to move past the length byte.
            loc += 1 + len;

            // Domain names are terminated by an empty label of length 0,
            // so if the length is zero we're done.
            if (len == 0) {
                break;
            }
        }

        try self.seek(loc);

        return iter;
    }
};
```

And the related tests to the read testing we added fir the integers:

```zig
test "BytePacketBuffer read testing" {
    
		-- snip --

		// Label reads
    const data = "\x03foo\x03bar\x08internal\x00\x05drink\xC0\x04\x06shaken\x03and\x07stirred\xC0\x12";
    @memcpy(buffer.buf[0..data.len], data);
    const alloc = std.testing.allocator;
    try buffer.seek(0);

    // testing a normal read
    var chain1 = try buffer.readLabelIterator();
    var result1 = std.ArrayList(u8).init(alloc);
    defer result1.deinit();
    try chain1.toFqdn(result1.writer());
    try std.testing.expectEqualStrings("foo.bar.internal.", result1.items);

    // testing a jumping read.
    var chain2 = try buffer.readLabelIterator();
    var result2 = std.ArrayList(u8).init(alloc);
    defer result2.deinit();
    try chain2.toFqdn(result2.writer());
    try std.testing.expectEqualStrings("drink.bar.internal.", result2.items);

    // testing a double jump read.
    var chain3 = try buffer.readLabelIterator();
    var result3 = std.ArrayList(u8).init(alloc);
    defer result3.deinit();
    try chain3.toFqdn(result3.writer());
    try std.testing.expectEqualStrings("shaken.and.stirred.drink.bar.internal.", result3.items);
}
```

A couple of points worth paying attention to in this part: the first is the usage of the interrogative (`?`) as the return type for `next()`. This is the Zig equivalent to Rust’s `Option<>`. There are a lot more details in the [zig.guide on Optionals](https://zig.guide/language-basics/optionals), but the main thing is that the interrogative allows a value to be `null`. A value is not allowed to be null if it isn’t marked with that `?`. We also see a usage of `catch` to convert an error into a null near the top of the function, since we cannot return errors in this implementation.

Another is the `writer: anytype` in the `toFqdn()` method. This is a bit of [duck-typing that Zig supports](https://ziglang.org/documentation/master/#Function-Parameter-Type-Inference) for function parameters. The language doesn’t have much in the way of interface support (more on that in [Chapter 5](./Chapter05.md)), but this can help when the type can be compile time inferred.

`var mut_self = self` might also seem a bit weird. All function parameters are const by default, so we were required to make a mutable copy of the iterator before we could start doing anything with it.

The `while` loop of `toFqdn()` is also an example of how to use the [zig style iterators](https://zig.guide/standard-library/iterators). The while loop will continue until `next()` returns `null`; the non-null value returned is captured in the bit between the pipe symbol (`|`). More details about [payload captures](https://zig.guide/language-basics/payload-captures) is available in the zig guide.

We’ll skip over the `Allocator` and `ArrayList` details in the test for now. We’ll do more with allocators in the [next chapter](./Chapter02.md).

That’s all the methods we need to extract data from a packet. It’s a lot of lines of code, and we glossed over a lot of the non-zig details because [Emil](https://github.com/EmilHernvall/dnsguide/blob/master/chapter1.md) has already covered them. Now we can shift to building the un-marshalled model.

## ResultCode

Introducing the Zig enum:

```zig
/// DNS Server Response Codes
const ResultCode = enum(u4) {
    no_error = 0,
    form_err = 1,
    serv_fail = 2,
    nx_domain = 3,
    not_imp = 4,
    refused = 5,
    yx_domain = 6,
    x_rrset = 7,
    not_auth = 8,
    not_zone = 9,

    pub fn fromNum(num: u4) ResultCode {
        switch (num) {
            0...9 => return @enumFromInt(num),
            else => return ResultCode.not_imp,
        }
    }
};
```

The `ResultCode` uses a u4, to demonstrate that unaligned sizes are supported in addition to the [normal types](https://ziglang.org/documentation/master/#Primitive-Types). I also went ahead and added more of the result codes that exist. The more interesting part is the fact that the [enum values are lowercase](https://github.com/ziglang/zig/issues/2101). This is because they are neither a type nor callable. The zig documentation has a section on naming in the [Zig style guide](https://ziglang.org/documentation/master/#Style-Guide).

## OpCode

```zig
/// DNS header OpCode that explains the type of query being done.
/// See https://www.iana.org/assignments/dns-parameters/dns-parameters.xhtml#dns-parameters-4
const OpCode = enum(u4) {
    query = 0,
    iquery = 1, // Obsolete,
    status = 2,
    unassigned = 3,
    notify = 4,
    update = 5,
    stateful_operations = 6,

    pub fn fromNum(num: u4) OpCode {
        switch (num) {
            0...2 => return @enumFromInt(num),
            4...6 => return @enumFromInt(num),
            else => return OpCode.unassigned,
        }
    }
};
```

This is similar to the `ResultCode`. Technically we don’t need to specify all of the constants for each enum value. Zig will automatically increment from previous one.

## Header

```zig
/// DNS Header structure.
const Header = struct {
    id: u16 = 0,

    recursion_desired: bool = false,
    truncated_message: bool = false,
    authoritative_answer: bool = false,
    opcode: OpCode = OpCode.query,
    response: bool = false,

    rescode: ResultCode = ResultCode.no_error,
    checking_disabled: bool = false,
    authed_data: bool = false,
    z: bool = false,
    recursion_available: bool = false,

    question_entries: u16 = 0,
    answer_entries: u16 = 0,
    authoritative_entries: u16 = 0,
    resource_entires: u16 = 0,

    fn read(buffer: *BytePacketBuffer) !Header {
        var header = Header{
            .id = try buffer.readU16(),
        };

        const flags = try buffer.readU16();
        const upper: u8 = @intCast(flags >> 8);
        const lower: u8 = @intCast(flags & 0xFF);

        header.recursion_desired = (upper & (1 << 0)) > 0;
        header.truncated_message = (upper & (1 << 1)) > 0;
        header.authoritative_answer = (upper & (1 << 2)) > 0;
        header.opcode = OpCode.fromNum(@truncate((upper >> 3) & 0x0F));
        header.response = (upper & (1 << 7)) > 0;

        header.rescode = ResultCode.fromNum(@truncate(lower & 0x0F));
        header.checking_disabled = (lower & (1 << 4)) > 0;
        header.authed_data = (lower & (1 << 5)) > 0;
        header.z = (lower & (1 << 6)) > 0;
        header.recursion_available = (lower & (1 << 7)) > 0;

        header.question_entries = try buffer.readU16();
        header.answer_entries = try buffer.readU16();
        header.authoritative_entries = try buffer.readU16();
        header.resource_entires = try buffer.readU16();

        return header;
    }

    pub fn format(
        self: Header,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        // blind reads so the compiler doesn't complain about unused parameters.
        _ = fmt;
        _ = options;

        try writer.print("opcode: {}, status: {}, id: {}, flags:", .{ self.opcode, self.rescode, self.id });
        if (self.response) {
            _ = try writer.write(" qr");
        }
        if (self.authoritative_answer) {
            _ = try writer.write(" aa");
        }
        if (self.truncated_message) {
            _ = try writer.write(" tc");
        }
        if (self.recursion_desired) {
            _ = try writer.write(" rd");
        }
        if (self.recursion_available) {
            _ = try writer.write(" ra");
        }
        if (self.z) {
            _ = try writer.write(" z");
        }
        try writer.print("; QUERY: {d}, ANSWER: {d}, AUTHORITY: {d}, ADDITIONAL: {d}", .{ self.question_entries, self.answer_entries, self.authoritative_entries, self.resource_entires });
    }
};
```

While the header looks like a lot of code, most of what we’ve added is twiddling bits and formatting a string. The `read` method is unpacking the header bytes into fields in a structure, and there isn’t anything very unique in the bitwise operations. Emil’s guide covers the finer points. 

The `format` method, which is what the string formatting methods will call, is a bit more interesting. We see the `anytype` parameter again, which was introduced with the `LabelIterator`. We also have a bunch of assignment to the `_` symbol. Assignments to underscore are how zig discards return values. the first one, `_ = fmt`, doesn’t make as much sense. In this case, the write is so the compiler doesn’t complain about the un-used parameter. I think the compiler is overly aggressive on this point, but it matches with the [Zig zen](https://ziglang.org/documentation/master/#Zen).

The output of format borrows heavily from the output of `dig`.

### Memory Leaks

The only heap allocations so far are at the very end of the testing block. Those allocations are immediately followed by a deferred called to `free`. This ensures that free is called when the scope unwinds, and prevents the memory from leaking.

I’m using the `std.testing.allocator`, which is designed to catch memory leaks. You can test this by commenting out the two lines that start with `defer` and run the tests. You will see the tests fail because of the leaked memory.

## QueryType

QueryType is another enum, and is relatively straightforward.

```zig
/// QueryType is a subset of query type.
///
/// See https://www.iana.org/assignments/dns-parameters/dns-parameters.xhtml#dns-parameters-4 for the full list.
const QueryType = enum(u16) {
    unknown,
    a,

    pub fn fromNum(num: u16) QueryType {
        switch (num) {
            0...1 => return @enumFromInt(num),
            else => return QueryType.unknown,
        }
    }
};
```

There are a lot more query types than `a`, but we are leaving them out as adding them now would mean a lot more code in the `Record` structure that we aren’t ready for yet.

## Question

For the sake of sticking with the standard, we are going to read the class and store it, but the reality is that we won’t see the other classes ever.

```zig
/// Question
const Question = struct {
    qname: BytePacketBuffer.LabelIterator,
    qtype: QueryType,
    qclass: u16, // always 1 for IN.

    fn read(buffer: *BytePacketBuffer) !Question {
        const qname = try buffer.readLabelIterator();
        const qtype = QueryType.fromNum(try buffer.readU16());
        const qclass = try buffer.readU16(); // Read the class from the buffer.

        return .{
            .qname = qname,
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

        var qname = self.qname;
        try qname.toFqdn(writer);
        try writer.print(" IN {s}", .{@tagName(self.qtype)});
    }
};
```

## Record

We’re going to structure this a little differently than Emil. Instead of repeating the preamble in each tagged type, we’re going to have `Record` and `RecordData` structures. This allows the record data to ignore the preamble.

```zig

/// Record is the common preamble at the start of all records.
/// I broke it into a different class to reduce the amount of code duplication.
const Record = struct {
    name: BytePacketBuffer.LabelIterator,
    rtype: u16,
    class: u16, // always 1 for IN.
    ttl: u32,
    data_len: u16,
    data: RecordData,

    fn read(buffer: *BytePacketBuffer) !Record {
        const name = try buffer.readLabelIterator();
        const rtype = try buffer.readU16();
        const class = try buffer.readU16(); // Class is always 1
        const ttl = try buffer.readU32();
        const data_len = try buffer.readU16();
        const data = try RecordData.read(rtype, data_len, buffer);

        return Record{
            .name = name,
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

        try self.name.toFqdn(writer);
        try writer.print(" {d} IN {s} {}", .{ self.ttl, @tagName(self.data), self.data });
    }
};

/// RecordData is a enum tagged union for each of the DNS types.
const RecordData = union(QueryType) {
    unknown: struct {},
    a: struct {
        addr: std.net.Ip4Address,
    },

    fn read(rt: u16, data_len: u16, buffer: *BytePacketBuffer) !RecordData {
        const rtype = QueryType.fromNum(rt);
        switch (rtype) {
            QueryType.a => {
                var addr_raw = [_]u8{ 0, 0, 0, 0 };
                addr_raw[0] = try buffer.read();
                addr_raw[1] = try buffer.read();
                addr_raw[2] = try buffer.read();
                addr_raw[3] = try buffer.read();
                const addr = std.net.Ip4Address.init(addr_raw, 0);

                return .{ .a = .{
                    .addr = addr,
                } };
            },
            QueryType.unknown => {
                // skip over the unknow data
                try buffer.step(data_len);
                return .{ .unknown = .{} };
            },
        }
    }

    pub fn format(
        self: RecordData,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        // blind reads so the compiler doesn't complain about unused parameters.
        _ = fmt;
        _ = options;

        switch (self) {
            .a => |r| {
                try writer.print("{}", .{r.addr});
            },
            .unknown => {
                try writer.print("{s}", .{"unknown"});
            },
        }
    }
};
```

`RecordData` introduces the tagged union, and shows how the pattern matches and payload captures work.

## Packet

The DNS Packet contains 5 sections: a header, a set of questions, a set of answers, a set of authoritative references, and a set of additional resources. We already did all the heavy lifting for this class. The one new thing is that we are going to need an [Allocator](https://zig.guide/standard-library/allocators) finally. There really isn’t a way around it, since we cannot know the number of questions and records in a payload at compile time.

The rest of this guide is going to tie most lifespans to the Packet, but we’ll get to that in the [next chapter](./Chapter02.md).

```zig

/// DNS Packet struct. Main entry point for dealing with DNS data.
const Packet = struct {
    header: Header,
    questions: std.ArrayList(Question),
    answers: std.ArrayList(Record),
    authorities: std.ArrayList(Record),
    resources: std.ArrayList(Record),
    allocator: std.mem.Allocator,

    fn init(alloc: std.mem.Allocator) Packet {
        var questions = std.ArrayList(Question).init(alloc);
        errdefer questions.deinit();
        var answers = std.ArrayList(Record).init(alloc);
        errdefer answers.deinit();
        var authorities = std.ArrayList(Record).init(alloc);
        errdefer authorities.deinit();
        var resources = std.ArrayList(Record).init(alloc);
        errdefer resources.deinit();

        return Packet{
            .header = Header{},
            .questions = questions,
            .answers = answers,
            .authorities = authorities,
            .resources = resources,
            .allocator = alloc,
        };
    }

    fn deinit(self: *Packet) void {
        self.questions.deinit();
        self.answers.deinit();
        self.authorities.deinit();
        self.resources.deinit();
    }

    fn read(alloc: std.mem.Allocator, buffer: *BytePacketBuffer) !Packet {
        var packet = Packet.init(alloc);
        errdefer packet.deinit();

        packet.header = try Header.read(buffer);

        try packet.questions.ensureTotalCapacityPrecise(packet.header.question_entries);
        for (0..packet.header.question_entries) |_| {
            try packet.questions.append(try Question.read(buffer));
        }
        try packet.answers.ensureTotalCapacityPrecise(packet.header.answer_entries);
        for (0..packet.header.answer_entries) |_| {
            try packet.answers.append(try Record.read(buffer));
        }
        try packet.authorities.ensureTotalCapacityPrecise(packet.header.authoritative_entries);
        for (0..packet.header.authoritative_entries) |_| {
            try packet.authorities.append(try Record.read(buffer));
        }
        try packet.resources.ensureTotalCapacityPrecise(packet.header.resource_entires);
        for (0..packet.header.resource_entires) |_| {
            try packet.resources.append(try Record.read(buffer));
        }

        return packet;
    }
};
```

We are capturing the `Allocator` during the `init` method. This is so that we can start allocating some heap memory when we need it in later chapters. We also use the allocator to setup several `ArrayLists`, which are used to provide expandable storage as we read the records.

We have to call `deinit` on each one of those `ArrayLists` to avoid leaking any memory. We accomplish this in two ways. The first is with the `deinit` method, which is basically a destructor. The second is with the [`errdefer` calls](https://zig.guide/language-basics/errors) in init. If an error happens during init, the lists will be de-initialized. This isn’t necessary since nothing returns an error state, but I wanted to introduce the keyword and show a best practice: every allocation should have an intentional release.

There is also a [`defer` keyword](https://zig.guide/language-basics/defer) as well. Unlike the Go version of defer, `defer` and `errdefer` are resolved at the exit of the scope, not the exit of the function.

## The real main file

For right now, we keep things simple. We’re going to read the response data from disk.

```zig
pub fn main() !void {
    var file = try std.fs.cwd().openFile("response_packet.txt", .{});
    defer file.close();

    var buffer = BytePacketBuffer{};
    _ = try file.reader().readAll(&buffer.buf);

    var gpa = std.heap.GeneralPurposeAllocator(std.heap.GeneralPurposeAllocatorConfig{}){};
    const alloc = gpa.allocator();

    var packet = try Packet.read(alloc, &buffer);
    defer packet.deinit();

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
}
```

Once that is all put together, we can run the code with the following command:

```
zigdnsguide % zig run src/main.zig
```

Assuming everything worked (please open an issue for any mistakes you encounter in the guide), we should see an output similar to this:

```
Header: opcode: main.OpCode.query, status: main.ResultCode.no_error, id: 6587, flags: qr rd ra; QUERY: 1, ANSWER: 1, AUTHORITY: 0, ADDITIONAL: 0
Question: google.com. IN a
Answer: google.com. 62 IN a 216.58.214.78:0
```

## Wrap-up

We have created all the parts necessary for reading DNS packets. Luckily, DNS uses the same packet format for writing. That allows us to jump into writing the query packet to a socket in the [next chapter](./Chapter02.md).

[Full source](../src/chapter01.zig) of this chapter.
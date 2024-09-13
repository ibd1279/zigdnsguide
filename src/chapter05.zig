const std = @import("std");

/// BufferError us used by the BytePacketBuffer for any errors.
/// Zig uses the bang (!) to denote a function **may** return an error.
const BufferError = error{
    BeyondEnd,
    TooManyJumps,
    LabelLengthExceeded,
};

/// LabelTrie is a trie for keeping track of labels inside of a Packet.
/// this a relatively straightforward Trie that allows for keeping track
/// of the location of labels already written.
const LabelTrie = struct {
    name: []const u8,
    position: ?usize,
    children: std.ArrayList(LabelTrie),

    const delimiter = '.';
    const root_name = "";

    /// Allocate a new node in the trie. Name must live as long as the trie.
    fn init(alloc: std.mem.Allocator, name: []const u8) LabelTrie {
        return LabelTrie{
            .name = name,
            .position = null,
            .children = std.ArrayList(LabelTrie).init(alloc),
        };
    }

    /// Destroy a node and all its children.
    fn deinit(self: LabelTrie) void {
        for (self.children.items) |child| {
            child.deinit();
        }
        self.children.deinit();
    }

    /// followPath adds a new path through the trie, and returns pointers
    /// to all the nodes.
    ///
    /// Iterate backwards through the array list until you get the jump node
    /// to write new nodes and update positions.
    fn followPath(root: *LabelTrie, name: []const u8) !std.ArrayList(*LabelTrie) {
        // Root was already passed in, so we can trim root off the name if it exists.
        var remaining = name.len;
        if (name[name.len - 1] == delimiter) {
            remaining -= 1;
        }

        // Init the result array.
        var list = std.ArrayList(*LabelTrie).init(root.children.allocator);
        errdefer list.deinit();
        try list.append(root);

        // We split backwards because of the DNS order.
        var iter = std.mem.splitBackwardsScalar(u8, name[0..remaining], delimiter);
        while (iter.next()) |label| {
            var child = try list.items[list.items.len - 1].addChild(label);
            errdefer child.deinit();
            try list.append(child);
        }

        return list;
    }

    /// addChild adds a child node to the trie. It initializes the child
    /// array list with the same allocator as the parent.
    fn addChild(self: *LabelTrie, name: []const u8) !*LabelTrie {
        // Don't allow names longer than the allowed label length.
        if (name.len > 0x3F) {
            return BufferError.LabelLengthExceeded;
        }

        // iteratie over the children to see if this child already exists.
        for (self.children.items) |*child| {
            if (std.mem.eql(u8, child.name, name)) {
                return child;
            }
        }

        // Create the orphan and adopt it.
        var orphan = LabelTrie.init(self.children.allocator, name);
        errdefer orphan.deinit();
        try self.children.append(orphan);
        return &(self.children.items[self.children.items.len - 1]);
    }
};

/// BytePacketBuffer encapsulates all the logic for buffering all the
/// reading and writing of the udp packets.
const BytePacketBuffer = struct {
    buf: [udp_packet_max]u8 = undefined,
    pos: usize = 0,
    label_cache: LabelTrie,

    /// Maximum length of a udp packet
    /// Zig doesn't have the traditional "static" concepts, but this gets close.
    const udp_packet_max = 512;

    fn init(alloc: std.mem.Allocator) BytePacketBuffer {
        return .{
            .label_cache = LabelTrie.init(alloc, LabelTrie.root_name),
        };
    }

    fn deinit(self: *const BytePacketBuffer) void {
        self.label_cache.deinit();
    }

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
        // Create the label chain, then we step past it.
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
        var path = try self.label_cache.followPath(qname);
        defer path.deinit();

        var jumped = false;
        for (0..path.items.len - 1) |i| {
            const h = path.items.len - i - 1;
            if (path.items[h].position) |jump_target| {
                const upper: u16 = 0xC0 << 8;
                const lower: u14 = @truncate(jump_target);
                try self.writeU16(upper | lower);
                jumped = true;
                break;
            } else {
                const start = self.pos;

                const name = path.items[h].name;
                const len: u8 = @truncate(name.len);
                try self.write(len);
                for (name) |c| {
                    try self.write(c);
                }
                path.items[h].position = start;
            }
        }

        if (!jumped) {
            // std.debug.print("wrote root at 0x{x}\n", .{self.pos});
            try self.write(0);
        }
    }
};

test "BytePacketBuffer basics testing" {
    var buffer = BytePacketBuffer.init(std.testing.allocator);
    defer buffer.deinit();

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

test "BytePacketBuffer read testing" {
    var buffer = BytePacketBuffer.init(std.testing.allocator);
    defer buffer.deinit();
    for (&buffer.buf, 0..) |*byte, i| {
        byte.* = @truncate(i & 0xFF);
    }

    // Integer reads
    try buffer.seek(1);
    try std.testing.expect(try buffer.readU16() == 0x0102);
    try std.testing.expect(try buffer.readU32() == 0x03040506);

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

test "BytePackteBuffer write testing" {
    const alloc = std.testing.allocator;
    var buffer = BytePacketBuffer.init(std.testing.allocator);
    defer buffer.deinit();
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

    pos = buffer.pos;
    const expectJumpFqdn = "martini.is.stirred.drink.bar.internal.";
    try buffer.writeName(expectJumpFqdn);
    try std.testing.expectEqual(@as(usize, 13), buffer.pos - pos);
    try buffer.seek(pos);
    var chain2 = try buffer.readLabelIterator();
    var result2 = std.ArrayList(u8).init(alloc);
    defer result2.deinit();
    try chain2.toFqdn(result2.writer());
    try std.testing.expectEqualStrings(expectJumpFqdn, result2.items);
}

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

/// QueryType is a subset of query type.
///
/// See https://www.iana.org/assignments/dns-parameters/dns-parameters.xhtml#dns-parameters-4 for the full list.
const QueryType = enum(u16) {
    unknown,
    a,
    ns,
    cname = 5,
    mx = 15,
    aaaa = 28,

    pub fn fromNum(num: u16) QueryType {
        switch (num) {
            0...2, 5, 15, 28 => return @enumFromInt(num),
            else => return QueryType.unknown,
        }
    }
};

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

    fn write(self: *const Question, buffer: *BytePacketBuffer) !void {
        try buffer.writeName(self.qname);
        try buffer.writeU16(@intFromEnum(self.qtype));
        try buffer.writeU16(self.qclass);
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

/// Record is the common preamble at the start of all records.
/// I broke it into a different class to reduce the amount of code duplication.
const Record = struct {
    name: []u8,
    rtype: u16,
    class: u16, // always 1 for IN.
    ttl: u32,
    data_len: u16,
    data: RecordData,

    // release the mory used by the Record.
    fn deinit(self: *const Record, alloc: std.mem.Allocator) void {
        self.data.deinit(alloc);
        alloc.free(self.name);
    }

    fn read(alloc: std.mem.Allocator, buffer: *BytePacketBuffer) !Record {
        const name = try buffer.readLabelIterator();
        const rtype = try buffer.readU16();
        const class = try buffer.readU16(); // Class is always 1
        const ttl = try buffer.readU32();
        const data_len = try buffer.readU16();
        const data = try RecordData.read(alloc, rtype, data_len, buffer);

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
        try buffer.setU16(size_pos, @truncate(buffer.pos - size_pos - 2));
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

/// RecordData is a enum tagged union for each of the DNS types.
const RecordData = union(QueryType) {
    unknown: struct {},
    a: struct {
        addr: std.net.Ip4Address,
    },
    ns: struct {
        host: []const u8,
    },
    cname: struct {
        host: []const u8,
    },
    mx: struct {
        priority: u16,
        host: []const u8,
    },
    aaaa: struct {
        addr: std.net.Ip6Address,
    },

    // release the mory used by the RecordData.
    fn deinit(self: *const RecordData, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .ns => |d| alloc.free(d.host),
            .cname => |d| alloc.free(d.host),
            .mx => |d| alloc.free(d.host),
            else => {},
        }
    }

    fn read(alloc: std.mem.Allocator, rt: u16, data_len: u16, buffer: *BytePacketBuffer) !RecordData {
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
            QueryType.ns => {
                const name = try buffer.readLabelIterator();

                var name_list = std.ArrayList(u8).init(alloc);
                defer name_list.deinit();
                try name.toFqdn(name_list.writer());
                const slice = try name_list.toOwnedSlice();

                return .{ .ns = .{
                    .host = slice,
                } };
            },
            QueryType.cname => {
                const name = try buffer.readLabelIterator();

                var name_list = std.ArrayList(u8).init(alloc);
                defer name_list.deinit();
                try name.toFqdn(name_list.writer());
                const slice = try name_list.toOwnedSlice();

                return .{ .cname = .{
                    .host = slice,
                } };
            },
            QueryType.mx => {
                const priority = try buffer.readU16();
                const name = try buffer.readLabelIterator();

                var name_list = std.ArrayList(u8).init(alloc);
                defer name_list.deinit();
                try name.toFqdn(name_list.writer());
                const slice = try name_list.toOwnedSlice();

                return .{ .mx = .{
                    .priority = priority,
                    .host = slice,
                } };
            },
            QueryType.aaaa => {
                var addr_raw: [16]u8 = undefined;
                for (&addr_raw) |*byte| {
                    byte.* = try buffer.read();
                }
                const addr = std.net.Ip6Address.init(addr_raw, 0, 0, 0);

                return RecordData{ .aaaa = .{
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

    pub fn write(self: *const RecordData, buffer: *BytePacketBuffer) !void {
        switch (self.*) {
            .a => |r| {
                const octets = @as(*const [4]u8, @ptrCast(&r.addr.sa.addr));
                try buffer.write(octets[0]);
                try buffer.write(octets[1]);
                try buffer.write(octets[2]);
                try buffer.write(octets[3]);
            },
            .ns => |r| try buffer.writeName(r.host),
            .cname => |r| try buffer.writeName(r.host),
            .mx => |r| {
                try buffer.writeU16(r.priority);
                try buffer.writeName(r.host);
            },
            .aaaa => |r| {
                const octets = @as(*const [16]u8, @ptrCast(&r.addr.sa.addr));
                for (octets) |byte| {
                    try buffer.write(byte);
                }
            },
            .unknown => |r| {
                // Skipping the unknown records for now but this will mess up the header counts.
                std.debug.print("Skipping records: {}\n", .{r});
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
            .ns => |r| {
                try writer.print("{s}", .{r.host});
            },
            .cname => |r| {
                try writer.print("{s}", .{r.host});
            },
            .mx => |r| {
                try writer.print("{d} {s}", .{ r.priority, r.host });
            },
            .aaaa => |r| {
                try writer.print("{}", .{r.addr});
            },
            .unknown => {
                try writer.print("{s}", .{"unknown"});
            },
        }
    }
};

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

    fn getRandomA(self: *const Packet) ?Record {
        const Filter = struct {
            pub fn do(_: @This(), r: Record) bool {
                switch (r.data) {
                    .a => |_| return true,
                    .aaaa => |_| return true,
                    else => return false,
                }
            }
        };

        var source = ArrayIterator(Record).init(self.answers.items);
        var iter = FilterIterator(Record, Filter).init(source.iter(), Filter{});
        return iter.next();
    }

    // filter to only NS records related to the name we want. Providing this as
    // a shared predicate class rather than a function
    const NsFilter = struct {
        qn: []const u8,
        pub fn do(s: @This(), record: Record) bool {
            switch (record.data) {
                .ns => {
                    if (std.mem.endsWith(u8, s.qn, record.name)) {
                        return true;
                    }
                    return false;
                },
                else => return false,
            }
        }
    };

    // Map NS recrods to their NS host value, basically unwrapping them.
    // Providing this as a shared predicate class rather than a function.
    const NsMapper = struct {
        pub fn do(_: @This(), record: Record) []const u8 {
            return switch (record.data) {
                .ns => |r| r.host,
                else => unreachable,
            };
        }
    };

    fn getResolvedNs(self: *const Packet, qname: []const u8) ?std.net.Address {
        var source = ArrayIterator(Record).init(self.authorities.items);
        var filter = FilterIterator(Record, NsFilter).init(source.iter(), NsFilter{ .qn = qname });
        var iter = MapIterator([]const u8, Record, NsMapper).init(filter.iter(), NsMapper{});
        while (iter.next()) |host| {
            var resources = ArrayIterator(Record).init(self.resources.items);
            while (resources.next()) |r2| {
                switch (r2.data) {
                    .a => |rec| {
                        if (std.mem.eql(u8, r2.name, host)) {
                            return std.net.Address{ .in = rec.addr };
                        }
                    },
                    .aaaa => |rec| {
                        if (std.mem.eql(u8, r2.name, host)) {
                            return std.net.Address{ .in6 = rec.addr };
                        }
                    },
                    else => {},
                }
            }
        }
        return null;
    }

    fn getUnresolvedNs(self: *const Packet, qname: []const u8) ?[]const u8 {
        var source = ArrayIterator(Record).init(self.authorities.items);
        var filter = FilterIterator(Record, NsFilter).init(source.iter(), NsFilter{ .qn = qname });
        var iter = MapIterator([]const u8, Record, NsMapper).init(filter.iter(), NsMapper{});
        return iter.next();
    }
};

/// A wrapper around a slice to allow iterator style acces.
fn ArrayIterator(comptime T: type) type {
    return struct {
        const Self = @This();
        source: []T,
        location: usize,

        /// Wrap the provided slice.
        pub fn init(ary: []T) Self {
            return .{
                .source = ary,
                .location = 0,
            };
        }

        /// Return the next item or null
        pub fn next(self: *Self) ?T {
            if (self.location >= self.source.len) {
                return null;
            }
            const val = self.source[self.location];
            self.location += 1;
            return val;
        }

        pub fn iter(self: *Self) Iterator(T) {
            return Iterator(T).init(self);
        }
    };
}
test "ArrayIterator test" {
    var ary = [_]u8{ 0, 1, 22, 38 };
    var iter = ArrayIterator(u8).init(&ary);
    var index: u8 = 0;
    while (iter.next()) |num| {
        try std.testing.expectEqual(ary[index], num);
        index += 1;
    }
    try std.testing.expectEqual(@as(u8, 4), index);
}
fn FilterIterator(comptime T: type, comptime Predicate: type) type {
    return struct {
        const Self = @This();
        source: Iterator(T),
        pred: Predicate,

        /// wrap the provided iterator with a filter.
        pub fn init(source: Iterator(T), pred: Predicate) Self {
            return .{
                .source = source,
                .pred = pred,
            };
        }

        /// return the next filtered item or null.
        pub fn next(self: *Self) ?T {
            while (self.source.next()) |item| {
                if (self.pred.do(item)) {
                    return item;
                }
            }
            return null;
        }

        pub fn iter(self: *Self) Iterator(T) {
            return Iterator(T).init(self);
        }
    };
}
test "FilterIterator tests" {
    var ary = [_]u8{ 0, 1, 22, 38 };
    var src = ArrayIterator(u8).init(&ary);

    const Pred = struct {
        needle: u8,
        const Self = @This();
        pub fn do(self: Self, val: u8) bool {
            if (val == self.needle) return true;
            return false;
        }
    };
    var iter = FilterIterator(u8, Pred).init(src.iter(), Pred{ .needle = 22 });
    var index: u8 = 0;
    while (iter.next()) |num| {
        try std.testing.expectEqual(@as(u8, 22), num);
        index += 1;
    }
    try std.testing.expectEqual(@as(u8, 1), index);
}
fn MapIterator(comptime T: type, comptime O: type, comptime M: type) type {
    return struct {
        const Self = @This();
        source: Iterator(O),
        mapper: M,

        pub fn init(source: Iterator(O), mapper: M) Self {
            return .{
                .source = source,
                .mapper = mapper,
            };
        }

        /// return the next mapped item or null.
        pub fn next(self: *Self) ?T {
            const val = self.source.next() orelse return null;
            return self.mapper.do(val);
        }

        pub fn iter(self: *Self) Iterator(T) {
            return Iterator(T).init(self);
        }
    };
}
test "MapIterator tests" {
    var ary = [_]u8{ 0, 1, 22, 38 };
    var src = ArrayIterator(u8).init(&ary);

    const Pred = struct {
        prefix: u8,
        const Self = @This();
        pub fn do(self: Self, val: u8) u16 {
            return @as(u16, self.prefix) << 8 | @as(u16, val);
        }
    };
    var iter = MapIterator(u16, u8, Pred).init(src.iter(), Pred{ .prefix = 0x01 });
    var index: u8 = 0;
    while (iter.next()) |num| {
        try std.testing.expectEqual(@as(u16, ary[index]) + 256, num);
        index += 1;
    }
    try std.testing.expectEqual(@as(u8, 4), index);
}
fn Iterator(comptime T: type) type {
    return struct {
        const Self = @This();
        ptr: *anyopaque,
        nextFn: *const fn (*anyopaque) ?T,

        pub fn init(ptr: anytype) Self {
            const Source = @TypeOf(ptr);
            const info = @typeInfo(Source);

            const Wire = struct {
                pub fn next(pointer: *anyopaque) ?T {
                    const self: Source = @ptrCast(@alignCast(pointer));
                    return info.Pointer.child.next(self);
                }
            };

            return .{
                .ptr = ptr,
                .nextFn = Wire.next,
            };
        }

        pub fn next(self: Self) ?T {
            return self.nextFn(self.ptr);
        }
    };
}

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
        if (recursiveLookup(alloc, question.qname, question.qtype)) |result| {
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

fn recursiveLookup(alloc: std.mem.Allocator, qname: []const u8, qtype: QueryType) !Packet {
    // For now we're always starting with *a.root-servers.net*.
    var ns = try std.net.Address.parseIp4("198.41.0.4", 0);

    // Since it might take an arbitrary number of steps, we enter an unbounded loop.
    while (true) {
        ns.setPort(53);
        std.debug.print("attempting lookup of {} {s} with ns {}\n", .{ qtype, qname, ns });

        const server = ns;
        var response = try lookup(alloc, qname, qtype, server);
        errdefer response.deinit();

        // If there are entries in the answer section, and no errors, we are done!
        if (response.answers.items.len > 0 and response.header.rescode == ResultCode.no_error) {
            return response;
        }

        // We might also get a `NXDOMAIN` reply, which is the authoritative name servers
        // way of telling us that the name doesn't exist.
        if (response.header.rescode == ResultCode.nx_domain) {
            return response;
        }

        // Otherwise, we'll try to find a new nameserver based on NS and a corresponding A
        // record in the additional section. If this succeeds, we can switch name server
        // and retry the loop.
        if (response.getResolvedNs(qname)) |new_ns| {
            ns = new_ns;

            continue;
        }

        // If not, we'll have to resolve the ip of a NS record. If no NS records exist,
        // we'll go with what the last server told us.
        const new_ns_name = response.getUnresolvedNs(qname) orelse return response;

        // Here we go down the rabbit hole by starting _another_ lookup sequence in the
        // midst of our current one. Hopefully, this will give us the IP of an appropriate
        // name server.
        const recursive_response = try recursiveLookup(alloc, new_ns_name, QueryType.a);

        // Finally, we pick a random ip from the result, and restart the loop. If no such
        // record is available, we again return the last result we got.
        if (recursive_response.getRandomA()) |new_ns| {
            ns = switch (new_ns.data) {
                .a => |r| std.net.Address{ .in = r.addr },
                .aaaa => |r| std.net.Address{ .in6 = r.addr },
                else => return response,
            };
        } else {
            return response;
        }
    }
}

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

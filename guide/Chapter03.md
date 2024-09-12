# Adding more Record Types

Before we add more record types, we are going to fix the name writing to support jumping around in a packet and saving some space in the packet. This isn’t required for the scope of the tutorial, but it did provide a more in-depth usage of optional and pointers.

To do this, we are going to create a container for keeping track of the location of labels inside the packet: a simple [trie](https://en.wikipedia.org/wiki/Trie).

## LabelTrie

This is an intrusive data structure (the element keeps track of the data-structure) rather than a non-intrusive (the data-structure keeps track of elements), mostly to keep things simple for implementation[^1]. We could make it non-intrusive and upgrade it with generics, but I’m saving introducing the generics to chapter 5.

We start by defining the Trie structure. We’re going to put this after the `BufferError` type, and before the `BytePacketBuffer` type.

```zig
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
};
```

The fields are
* A `name` for the label of the domain name. This is the key on the trie.
* A `position` for the location in the packet. This is the value on the trie. It is optional, because we’ll set the value once we write the label to the packet.
* A list of `childern` for keeping track of the previous label. This is the structure of the trie.

This isn’t a very smart trie. In the worst-case, we’re going to be scanning the entire `children` list to find the children we want. That is OK for this guide, and may be OK outside of this guide since we will have one trie per packet, so the structure is never going to become excessively large. 15 to 30 entries in the worst case.

The node owns the memory for the array backing `childern`, so the `init` and `deinit` functions are required.

The logic of the trie is implemented in these last two functions to read and write branches.

```zig
const LabelTrie = struct {

		-- snip --

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
```

In `followPath`, a name is passed in. While officially domain-names all end in a delimiter (`.`) to denote the root server, humans regularly for get to add that detail. The first two stanzas make the method work both with and with out the last delimiter.

The last stanza in `followPath` does the work of iterating through the name backwards (e.g. in the order of “com”, “google”, “www”), and appending the children to the list that will be returned. All of this depends on how `addChild` behaves. `addChild` enforces the length limits on labels, checks to see if the child already exists (and returns it if it does), and adds the new child (and returns it).

We add tests afterwards to make sure the logic works:

```zig
test "LabelTrie test" {
    const alloc = std.testing.allocator;
    var root = LabelTrie.initRoot(alloc);
    defer root.deinit();

    // Populate the initial bits
    {
        var com_google = try root.addBranch("google.internal");
        defer com_google.deinit();
        try std.testing.expectEqual(3, com_google.items.len);
        com_google.items[1].position = 0x14;
        com_google.items[2].position = 0x0C;
    }

    // Test adding a new domain.
    {
        const com_yahoo = try root.addBranch("yahoo.internal.");
        defer com_yahoo.deinit();
        try std.testing.expectEqual(3, com_yahoo.items.len);
        try std.testing.expectEqual(null, com_yahoo.items[2].position);
        try std.testing.expectEqual(0x14, com_yahoo.items[1].position);
    }

    // Test getting an existing domain.
    {
        const com_google = try root.addBranch("google.internal.");
        defer com_google.deinit();
        try std.testing.expectEqual(3, com_google.items.len);
        try std.testing.expectEqual(0x0C, com_google.items[2].position);
        try std.testing.expectEqual(0x14, com_google.items[1].position);
    }

    // Test getting something completely different.
    {
        const fr_gouv_impots = try root.addBranch("impots.gouv.fr");
        defer fr_gouv_impots.deinit();
        try std.testing.expectEqual(4, fr_gouv_impots.items.len);
        try std.testing.expectEqual(null, fr_gouv_impots.items[3].position);
        try std.testing.expectEqual(null, fr_gouv_impots.items[2].position);
        try std.testing.expectEqual(null, fr_gouv_impots.items[1].position);
    }
}
```

With that in place, we can update the `BytePacketBuffer` type. These changes are going to be adding the trie to the buffer lifetime, and changing how `writeName` works.

```zig
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

		-- snip --
		
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
```

This is sadly a breaking change. Up to this point, we’ve been taking advantage of the default values provided on the `BytePacketBuffer`. But we’ve now added a field that cannot have a default value because it needs an allocator.

The simplest way to find all the places that we need to change is to try building or running the tests again. We’ll need to update each of these points where the buffer was initially created with the call to `init` and a deferred call to `deinit`

```
zigdnsguide % zig test src/main.zig
src/main.zig:345:34: error: missing struct field: label_cache
    var buffer = BytePacketBuffer{};
                 ~~~~~~~~~~~~~~~~^~
src/main.zig:92:26: note: struct 'main.BytePacketBuffer' declared here
const BytePacketBuffer = struct {
                         ^~~~~~
src/main.zig:377:34: error: missing struct field: label_cache
    var buffer = BytePacketBuffer{};
                 ~~~~~~~~~~~~~~~~^~
src/main.zig:92:26: note: struct 'main.BytePacketBuffer' declared here
const BytePacketBuffer = struct {
                         ^~~~~~
src/main.zig:416:34: error: missing struct field: label_cache
    var buffer = BytePacketBuffer{};
                 ~~~~~~~~~~~~~~~~^~
src/main.zig:92:26: note: struct 'main.BytePacketBuffer' declared here
const BytePacketBuffer = struct {
                         ^~~~~~
```

The usages in tests can become:

```zig
    var buffer = BytePacketBuffer.init(std.testing.allocator);
    defer buffer.deinit();
```

Once all the tests are passing again, we can add one more write test. This one will ensure that the next string we write is shorter than the memory representation of the string was.

```zig
test "BytePackteBuffer write testing" {

		-- snip --
		
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
```

In this test, we are taking the string `martini.is.stirred.drink.bar.internal.` and writing it in 13 bytes, but when we read the string back, we get the full string back. Our implementation now supports writes that jump around.

If look closely in that block of code, we’ll see the line `try std.testing.expectEqual(@as(usize, 13), buffer.pos - pos);`. We see this often in tests in zig, and it is considered by some to be a quirk of the language (number 9 on [this list](https://www.openmymind.net/Zig-Quirks/)). The `actual` value is coerced into the `expected` value. That becomes problematic when a compile time constant is provided, since a runtime value can not be coerced into a compile time value. We work around it with using the `@as()` cast builtin.

Before we get back to record types, we need to do one more thing: run the application. There are two more locations where we haven’t called `BytePacketBuffer.init`:

```
zigdnsguide % zig run src/main.zig 
src/main.zig:969:38: error: missing struct field: label_cache
    var req_buffer = BytePacketBuffer{};
                     ~~~~~~~~~~~~~~~~^~
src/main.zig:92:26: note: struct 'main.BytePacketBuffer' declared here
const BytePacketBuffer = struct {
                         ^~~~~~
referenced by:
    callMain: /opt/homebrew/Cellar/zig/0.13.0/lib/zig/std/start.zig:524:32
    callMainWithArgs: /opt/homebrew/Cellar/zig/0.13.0/lib/zig/std/start.zig:482:12
    remaining reference traces hidden; use '-freference-trace' to see all reference traces
```

We have to update the `req_buffer` and the `res_buffer` in the main function. Once those call main (add the deferred deinit), we’re ready to add more record types.

[^1] [boost.org: Intrusive and non-intrusive containers](https://www.boost.org/doc/libs/1_55_0/doc/html/intrusive/intrusive_vs_nontrusive.html)

## Switching to yahoo.com

Instead of looking up `google.com`, let’s change it so that we try to look up `www.yahoo.com`, in the `main` function.

```zig
    const qname = "www.yahoo.com";
```

The `www.` is important here. If you leave that out, you won’t get the same results:

```
zigdnsguide % zig run src/main.zig
Header: opcode: main.OpCode.query, status: main.ResultCode.no_error, id: 6666, flags: rd; QUERY: 1, ANSWER: 0, AUTHORITY: 0, ADDITIONAL: 0
Question: www.yahoo.com IN a
Header: opcode: main.OpCode.query, status: main.ResultCode.no_error, id: 6666, flags: qr rd ra; QUERY: 1, ANSWER: 3, AUTHORITY: 0, ADDITIONAL: 0
Question: www.yahoo.com. IN a
Answer: www.yahoo.com. 54 IN unknown unknown
Answer: me-ycpi-cf-www.g06.yahoodns.net. 54 IN a 87.248.114.12:0
Answer: me-ycpi-cf-www.g06.yahoodns.net. 54 IN a 87.248.114.11:0
```

In order to make sense of that `unknown` record, we need to add support for some more record types. [Emil’s guide](https://github.com/EmilHernvall/dnsguide/blob/master/chapter3.md) provides a description of the top 5 most common.

## Extending QueryType

We used QueryType for the tag on our RecordData tagged union, so we have to start here to expand the number of tags:

```zig
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
```


## Extending RecordData

All of the logic for the different types is encapsulated in the `RecordData` class, so this is where we make the most changes.

```zig
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
```

The main thing to note is that we replaced `_: std.mem.Allocator` with `alloc: std.mem.Allocator`. We are using the allocator now, so it needs a proper name. The rest is implementing customer read, write, and print methods for each of the new types.

## Running the program

If you run the program now, instead of getting any unknown records, you’ll get the cname record for `www.yahoo.com`.

```
zigdnsguide % zig run src/main.zig
Header: opcode: main.OpCode.query, status: main.ResultCode.no_error, id: 6666, flags: rd; QUERY: 1, ANSWER: 0, AUTHORITY: 0, ADDITIONAL: 0
Question: www.yahoo.com IN a
Header: opcode: main.OpCode.query, status: main.ResultCode.no_error, id: 6666, flags: qr rd ra; QUERY: 1, ANSWER: 3, AUTHORITY: 0, ADDITIONAL: 0
Question: www.yahoo.com. IN a
Answer: www.yahoo.com. 24 IN cname me-ycpi-cf-www.g06.yahoodns.net.
Answer: me-ycpi-cf-www.g06.yahoodns.net. 24 IN a 87.248.114.12:0
Answer: me-ycpi-cf-www.g06.yahoodns.net. 24 IN a 87.248.114.11:0
```

And now we have a stub resolver that can handle many more types of records. The Trie allowed us to create our own container and support larger (more repetitive) packets, and we now support more record types.

In [chapter 4](./Chapter04.md), we’ll focus more on converting our stub resolver into a dns proxy server, before we get to playing with some iterators, interfaces, and generics in [chapter 5](./Chapter05.md).



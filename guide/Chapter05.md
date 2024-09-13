# Recursive Resolve, Comptime, and Zig’s “Interfaces”

Before we get to the recursive resolver that [Emil implements](https://github.com/EmilHernvall/dnsguide/blob/master/chapter5.md), we’re going to explore a couple of parts of zig to attempt to make the code a little bit easier to implement.

## ArrayIterator

The first thing we are going to play with is creating our own iterator class for `Record` items. As we already saw with the LabelIterator, Iterators in zig usually do not have the own memory, but instead have the logic for iterating over memory owned by something else. [DanTheDev](https://danthedev.com/zig-iterators/) has a good blog post covering Iterators.

We’re going to make a simple iterator that iterates over an array. We’re going to make this a generic type, that can iterate over the array of any type of array:

```zig
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
```

ArrayIterator is a function. Specifically, it is a function that is executed at compilation time, and returns a type. In our test case, it returns a type that will be backed by a slice of u8. Then we call the `init()` function on that type to create a new instance of that type with the provided array as a source.

These [comptime](https://zig.guide/language-basics/comptime) functions are how Zig implements their generic type system and cover many of the use-cases of macros. But rather than creating a distinct templating language, Zig attempts to make it feel like normal Zig code executed before/during compilation.

If we wanted, we could go back and make our `LabelTrie` a generic structure, but that isn’t covered by this guide.

## Streaming iterators

For the next part of Emil’s guide, we would have an easier time matching his code if we had some streaming iterators. We could add a dependency like [zignite](https://github.com/shunkeen/zignite) to do that, but it is easy enough to implement the small subset of operators that we need ourselves.

We’ll start with the filter operation. This will call `next` on the underlying iterator until a value matches the provided predicate:

```zig
fn FilterIterator(comptime T: type, comptime Predicate: type) type {
    return struct {
        const Self = @This();
        source: ArrayIterator(T),
        pred: Predicate,

        /// wrap the provided iterator with a filter.
        pub fn init(source: ArrayIterator(T), pred: Predicate) Self {
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
    };
}
test "FilterIterator tests" {
    var ary = [_]u8{ 0, 1, 22, 38 };
    const src = ArrayIterator(u8).init(&ary);

    const Pred = struct {
        needle: u8,
        const Self = @This();
        pub fn do(self: Self, val: u8) bool {
            if (val == self.needle) return true;
            return false;
        }
    };
    var iter = FilterIterator(u8, Pred).init(src, Pred{ .needle = 22 });
    var index: u8 = 0;
    while (iter.next()) |num| {
        try std.testing.expectEqual(@as(u8, 22), num);
        index += 1;
    }
    try std.testing.expectEqual(@as(u8, 1), index);
}
```

This one is a bit more complicated, as we have two input types to our function: `T` for the return type of the iterator and `Predicate` for the type of the predicate that will be run.

In the test, we have to create an anonymous type with a `do` method on it to be the predicate. This is as close as Zig gets to anonymous functions right now.

## MapIterator

The final iterator type we’ll make is the MapIterator. This is very similar to the filter iterator, except the predicate returns the new value instead of returning a boolean.

```zig
fn MapIterator(comptime T: type, comptime O: type, comptime M: type) type {
    return struct {
        const Self = @This();
        source: ArrayIterator(O),
        mapper: M,

        pub fn init(source: ArrayIterator(O), mapper: M) Self {
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
    };
}
test "MapIterator tests" {
    var ary = [_]u8{ 0, 1, 22, 38 };
    const src = ArrayIterator(u8).init(&ary);

    const Pred = struct {
        prefix: u8,
        const Self = @This();
        pub fn do(self: Self, val: u8) u16 {
            return @as(u16, self.prefix) << 8 | @as(u16, val);
        }
    };
    var iter = MapIterator(u16, u8, Pred).init(src, Pred{ .prefix = 0x01 });
    var index: u8 = 0;
    while (iter.next()) |num| {
        try std.testing.expectEqual(@as(u16, ary[index]) + 256, num);
        index += 1;
    }
    try std.testing.expectEqual(@as(u8, 4), index);
}
```

## Interfaces

At this point, we’ve created a bit of a problem. As designed, we don’t have a way to use `FilterIterator` and `MapIterator` together. That’s because both expect the source to be an `ArrayIterator(T)`. We already saw a hint on how to change this when we implemented the `anytype` stuff for the `format()` methods, so we need to leverage that to create some form of dynamic dispatch.

We’re going to create an `Iterator` interface. This is more labor intensive than it would be in other languages, as Zig doesn’t have a native interface concept, but we can get relatively close by implementing a simple v-table class:

```zig
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
```

The `init()` method on that type is doing some weird looking stuff, as it is a function, returning a type with an init function that creates another type, that effectively creates a v-table for us. Karl Seguin had a relatively good post on how this [interface thing works](https://www.openmymind.net/Zig-Interfaces/), but I also found the post by [KilianVounckx](https://zig.news/kilianvounckx/zig-interfaces-for-the-uninitiated-an-update-4gf1) to be really useful as well. The main thing to understand is that a version of the `Wire` structure will be generated to bridge between this interface and whatever type is passed as `ptr: anytype` value.

This new `Iterator(T)` structure allows us to turn any of our previous Iterators into a type erased iterator, we just need to provide some simple ways to convert our concrete iterators into this new interface.

So we go back to our other iterators, and the final code should look like this:

```zig
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
```

There are a bunch of little changes in the tests beyond changing the `source` field type and the addition of an `iter()` method, so it’s a little easier to just paste the whole block[^1]. We’ll run the `zig test` command to make sure these iterator structures work before move on to the next step:

```
zigdnsguide % zig test src/main.zig
All 6 tests passed.
```

With all that code out of the way, we can now mimic some of the streaming iterators that were used in Emil’s Rust version.

An interesting aspect of this is that the duct typing technically allows us to use any type that has a `next()` method  for the interface. This is because of the `anytype` parameter that would make a new wire-class for that type when it encounters it.

[^1]: There aren’t really that many changes, but I felt discussing these was more of a distraction than the text needed: the intermediate iterator changes from `const` to `var`, and we call `iter()` when passing one iterator to another.

## Extending Packet for recursive lookups

`getRandomA` is used to extract a random A record from a DNS response. It will also return `AAAA` records. 

```zig
const Packet = struct {

		-- snip --

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
};
```

We switch on the `r.data` (the `RecordData`) instead of the `rtype` field, because we want the tagged union (the enum value) rather than the untype int value.

The “anonymous” function we use for our predicate has to be defined inside some scope, so in this case. We make a local structure and put the method on it. Maybe a future version of zig will support more anonymous functions, but this is how they are implemented today -- with a local name in a inaccessible scope.

## Getting NS records

We are going to replace the `get_ns()` method that Emil returns, with two shared predicates. We cannot return an iterator the way Emil does because one of the predicates (the `NsFilter`) captures state (the runtime `qname` parameter).

The challenge here is the lifetime of the returned objects. The Predicates that we could initialize inside our potential `getNs()` would be released when the stack unwound. We could allocate some memory, but then someone needs to be responsible for releasing the memory. There could be some ways around it using an arena allocator, it isn’t worth the slight reduction in duplicated code compared to this approach.

The two shared predicates are: 

```zig
const Packet = struct {

		-- snip --

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
};
```

That takes us to `getResolvedNs()` and it’s sibling, `getUnresolvedNs()`:

```zig
const Packet = struct {

		-- snip --

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
```

We could make this a little smaller by moving our “anonymous” functions into a shared name scope (`Packet` in this case), but leaving for for a later change.

## The actual recursive look-up

The recursive lookup is pretty close to Emil’s version. The biggest difference is that it’s designed to support IPv6 as part of look-ups as well.

```zig
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
```

After that, we also have to make a small change to how `handleQuery` works:

```zig
fn handleQuery(alloc: std.mem.Allocator, socket: std.posix.socket_t) !void {

		-- snip --

        if (recursiveLookup(alloc, question.qname, question.qtype)) |result| {

		-- snip --

}
```

Here, removed the `const server = ` assignment we used to target 8.8.8.8, and replaced the `lookup()` call with a `recursiveLookup()` call.

## Testing the server again

Similar to the end of chapter 2, we need two terminal sessions to test our server. Run the server in the first session with `zig run src/main.zig`. In the second terminal window run

```
dig @localhost -p 2053 yahoo.com
```

On the server terminal, you’ll see output that looks like this:

```
zigdnsguide % zig run src/main.zig
Received query: yahoo.com. IN a
attempting lookup of main.QueryType.a yahoo.com. with ns 198.41.0.4:53
attempting lookup of main.QueryType.a yahoo.com. with ns 192.41.162.30:53
attempting lookup of main.QueryType.a yahoo.com. with ns [2001:4998:1b0::7961:686f:6f21]:53
Answer: yahoo.com. 1800 IN a 74.6.231.20:0
Answer: yahoo.com. 1800 IN a 74.6.231.21:0
Answer: yahoo.com. 1800 IN a 98.137.11.163:0
Answer: yahoo.com. 1800 IN a 98.137.11.164:0
Answer: yahoo.com. 1800 IN a 74.6.143.25:0
Answer: yahoo.com. 1800 IN a 74.6.143.26:0
```

You should be able to try some other requests too. For example

```
dig @localhost -p 2053 -t mx github.com
```

Will show something like the following on the server terminal:

```
Received query: github.com. IN mx
attempting lookup of main.QueryType.mx github.com. with ns 198.41.0.4:53
attempting lookup of main.QueryType.mx github.com. with ns 192.41.162.30:53
attempting lookup of main.QueryType.mx github.com. with ns 205.251.193.165:53
Answer: github.com. 3600 IN mx 1 aspmx.l.google.com.
Answer: github.com. 3600 IN mx 10 alt3.aspmx.l.google.com.
Answer: github.com. 3600 IN mx 10 alt4.aspmx.l.google.com.
Answer: github.com. 3600 IN mx 5 alt1.aspmx.l.google.com.
Answer: github.com. 3600 IN mx 5 alt2.aspmx.l.google.com.
Authority: github.com. 900 IN ns dns1.p08.nsone.net.
Authority: github.com. 900 IN ns dns2.p08.nsone.net.
Authority: github.com. 900 IN ns dns3.p08.nsone.net.
Authority: github.com. 900 IN ns dns4.p08.nsone.net.
Authority: github.com. 900 IN ns ns-1283.awsdns-32.org.
Authority: github.com. 900 IN ns ns-1707.awsdns-21.co.uk.
Authority: github.com. 900 IN ns ns-421.awsdns-52.com.
Authority: github.com. 900 IN ns ns-520.awsdns-01.net.
```

## Wrapping up

This gets us to the same place us to the same destination as [Emil’s guide](https://github.com/EmilHernvall/dnsguide/blob/master/chapter5.md). We’ve now implemented a proof of concept DNS recursive lookup DNS server.

It isn’t ready for production (for example, try hitting the server with this command: `dig @localhost -p 2053 -t a`), but it did allow us to cover many of the different aspects of the zig language. We didn’t go too deep into any of the specific features of the language, but hopefully this guide was enough to encourage you to start exploring on your own.
# Building [EmilHernvall’s DNS server](https://github.com/EmilHernvall/dnsguide) in ~~Rust~~Zig

When I was looking for a smallish project to start learning Rust, I found a reddit post that suggested [EmilHernvall’s DNS server](https://github.com/EmilHernvall/dnsguide) as a great way to get into the language, do something with a specific standard, but also not overwhelming. I found it to be just the right way to get into the language, and to refresh my memory of [how DNS works](https://www.ietf.org/rfc/rfc1035.txt). 

As someone who mostly worked in [Go](https://go.dev) the past 5 years, I found rust a bit too uncomfortable for my tastes, and started looking at [Zig](https://ziglang.org). After cobbling my path through the language (it could really use some help in the documentation space), I decided to try doing the same DNS server. The result is this guide.

I’m new to Zig, so many of the things here are what I *imagine* are the idiomatic ways to do things, and I welcome pointers or recommendations to more idiomatic approaches. Like Zig, this guide is a work in progress, and will probably become out of date rapidly as the Zig language and features evolve. I used [Zig 0.13.0](https://ziglang.org) for doing this.

If you are completely new to Zig, I suggest you start with the [Zig documentation](https://ziglang.org/learn/) first. Then come back to this when you want to try something more complex.

The guide is broken into 5 main chapters that follow Emil’s:

* [Emil’s README.md](https://github.com/EmilHernvall/dnsguide/blob/master/README.md)
* [Chapter 0 - Initial Setup](./guide/Chapter00.md)
* [Chapter 1 - Reading DNS Data and Zig’s Result](./guide/Chapter01.md)
* [Chapter 2 - Writing DNS Data and Zig’s Option](./guide/Chapter02.md)
* [Chapter 3 - Adding more Record Types and Zig’s Tagged Unions](./guide/Chapter03.md)
* [Chapter 4 - First DNS Server and Memory Lifetimes](./guide/Chapter04.md)
* [Chapter 5 - Recursive Resolve, Comptime, and Zig’s “Interfaces”](./guide/Chapter05.md)


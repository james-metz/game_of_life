# Game of Life 

This is a simple CLI for the Game of life. I am working to understand memory management better, and work with Zig. 

I used some LLM assistance in the early stages to get some of the basic IO operations setup, but will be improving it without direct coding assistance to wrap my head around manual memory management.

## Dev Log

**Aug 23, 2026 - Currently it is functional**

While the system does work, the iteration is really slow and needs alot of work. I think I will focus next on ensuring no additional allocations happen on every frame.

I have made a bunch of progress, and now there is no flickering with a avg fps: 7190.92 with a 10 nanosecond delay. (hypothetically with 10ns delay, max fps would be 100 million per second.)

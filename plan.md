# Plan for Wozmon64
---
## Overview
This project will be a "reimagining" of Steve Wozniak's Apple I WozMon on AMD64 called Wozmon64.  The monitor will run in high memory (0xFFFF_FFFF_8000_0000). The bootloader will be written for UEFI. Everything will be written in Zig, AMD64 assembly and possibly C if I use any external libraries.

Like the original WozMon, the source code will be open. Unlike BoksOS, I plan to commit to GitHub as the project moves along.

In the spirit of Apple I and other microcomputers afterwards, I'd also like to have the philosophy of a "fixed machine". I'd like to shy away from optional support of certain hardware features that some PCs may support, but not others (e.g. AVX-512 and Hyperthreading). Basically, if Wozmon64 uses a hardware feature, it will become a requirement. Though, Wozmon64 will support a variable number of CPU cores and a variable amount of memory.

## Purpose
I've been kind of in a rut with BoksOS, so I want to start a fresh project with a clear goal that would also help support BoksOS.

This will basically be a simple "operating system" where a majority of the complexity will be the drivers. I will then use the driver code I write for Wozmon64 in BoksOS.  I will also share a lot of BoksOS code with this project.

It'd also be nice if this could be used as some sort of educational tool to teach how computers work at a low level.

## Development Pace
I plan to develop Wozmon64 in tandem with BoksOS.  So like BoksOS, development will be slow, but all commits will be public.

## Usage
Wozmon64 will be line based and support similar syntax as the original WozMon. That is, the "commands" you enter are memory addresses and whether you want to read from them, write to them, or execute them. In the examples below, `[ENTER]` will represent hitting the enter key, while `[RESPONSE]` means that's what the monitor responded with.

- Entering a hex value is interpreted as a memory address. Wozmon64 will output the value at that address. Example:

    ```
    C000F0[ENTER]
    [RESPONSE]C0_00F0: 04
    ```

- Entering a range will print out a range of bytes. Example:

    ```
    C000F0.C000F4[ENTER]
    [RESPONSE]C0_00F0: 00 33 55 66
    ```

- Entering a "." followed by an address will print a range of address following the last "opened" address. Example:
    ```
    C000F0.C000F4[ENTER]
    [RESPONSE]C0_00F0: 00 33 55 66

    .C0000F8[ENTER]
   [RESPONSE] C0_00F5: 11 CD AB
    ```
- Using the `:` operator will allow you write bytes into memory. When writing into memory, the previous value of the memory will be printed out.  Example:
    ```
    C000F0[ENTER]
    [RESPONSE]C0_00F0: AA BB CC

    C000F0: AA[ENTER]
    [RESPONSE]C0_00F0: 00 00 00

    C000F0.C000F2[ENTER]
    [RESPONSE]C0_00F0: AA BB CC
    ```

- Appending an "R" to an address will begin execution of whatever instruction is at that address. In the following example, we put the binary code `EB FE`, which disassembles to `l: jmp l`, an infinite loop. Example:

    ```
    C000F0: EB FE[ENTER]
    C000F0R[ENTER]
    ```

- If you try to read, write, or execute the first 2MiB, which I call the `Null Memory`, you will get an error. Example:
    ```
    F0[ENTER]
    [RESPONSE]NULL MEMORY EXCEPTION
    ```


You can play with similar commands on an Apple I emulator here: https://www.scullinsteel.com/apple1/ (be sure to hit the RESET key to start using it).  The max address on the Apple I is 0xFFFF, so try reading from an address like `FF00` (which is where WozMon lives in memory!).

## Running Programs
Fundamentally, Wozmon64 is a single-program system. But, it will support multiple cores, so you can have multiple tasks of a program run simultaneously.  

One way to run a program on Wozmon64 is to enter the binary at a usable RAM address and then run with the `R` prefix as noted above.  You can then exit back to the monitor by hitting `Ctrl-Escape` or the `Pause/Break` key.  This implies that the monitor is permenently resident in memory and runs on one core, while your program will run on the other core(s).

Programs will also immediately exit to the monitor if they cause an AMD64 exception.  An appropriate error message will be printed to the screen.

Now, for any sufficent program, inputting it manually is, to put it lightly, not ideal.  I will have to think more on what to do with this, but my initial solution is to have a directory in the boot media for programs and use the UEFI mass storage API to load all programs in that directory into the monitor address space on startup.  I will then have a special program called the **Program Selector** at a fixed address in the memory map you can run directly.  This program will then list the programs available and ask the user which one to run and what address to load it to.  

This is would be similar to running the program at C100 on the Apple I to load programs from a cassette.

Perhaps in the future we can have mass media driver in the monitor where we can load programs from the mass media on demand instead of at start up.

## Writing Programs for Wozmon64
Programs for Wozmon64 will be assembled AMD64 instructions that you will load directly into RAM. As such, any files that are Wozmon64 programs will be flat binary files with no header.  Wozmon64 will provide a couple of system-wide procedures and runtime constants that a program can execute to interact with the hardware. The calling convention of these procedures will follow the [64-bit version of the System V calling convention](https://wiki.osdev.org/Calling_Conventions). Here are the Zig function signatures, required data structures of the procedures and runtime constants:

```zig
const KeyEvent = union(enum) {
    KeyDown: UsageID
    KeyUp: UsageID

    //this corresponds to Usage ID of Keyboard/Keypad page of the USB HID usage table. 
    //See page 53 of https://www.usb.org/sites/default/files/documents/hut1_12v2.pdf
    const UsageID = u8;
};

//returns true if there is an event, else false
const poll_keyboard = @intToPtr(*const fn(out_event: *KeyEvent) callconv(.C) bool, 0xA0_0000);

const MouseEvent = union(enum) {
    MouseMoved: struct {dx: i16, dy: i16},
    ScrollMoved: struct {dx: i16, dy: i16},
    ButtonUp: Button,
    ButtonDown: Button,
    const Button = enum{Left, Middle, Right},
};
//returns true if there is an event, else false
const poll_mouse = @intToPtr(*const fn(out_event: *MouseEvent) callconv(.C) bool, 0xA0_0008); 

//returns true on success, else false.  core_number must be >= 1 and < N_CORES (core 0 is reserved for the monitor)
const run_on_core = @intToPtr(*const fn(entry_point: *const fn(arg: ?*anyopaque) callconv(.C) void, arg: ?*anyopaque, core_number: u64) callconv(.C) bool, 0xA0_0010);

//runtime constant that contains the number of cores of the machine
const N_CORES = @intToPtr(*const u64, 0xA0_0018);

//runtime constant that contains the highest usable RAM address
const MAX_RAM_ADDRESS = @intToPtr(*const u64, 0xA0_0020);
```


## System Requirements
- AMD64 CPU with at least 2 physical cores (threads don't count!).
- Motherboard with UEFI.
- Graphics chip that supports UEFI Graphics Output Protocol (GOP).
- Graphics chip and video monitor that supports a resolution of 1920x1080.

## Features

- Supports 64-bit addresses and virtual memory.
- Supports true backspace.
- Error messages for bad input and runtime errors.
- 1980x1080 24-bit color screen will be pixel-based as opposed to character-based.
- Multi-core support, though the monitor itself will only be single threaded.

As of now the monitor will have drivers for the following devices:

- USB Keyboard driver
- USB Mouse driver (maybe unnecessary, but I already have some of that code written)
- Graphics via framebuffer.  Resolution is fixed at 1920x1080.

In the future we could support:
- Sound
- USB Mass storage
- Ethernet with TCP/IP stack and maybe a QUIC stack

## Memory Map

This will be the virtual memory map of Wozmon64.  2MiB pages are used, so there maybe some invalid address space after some MMIO memory.

| Address Range | Size | Name | Description |
| ------------- | ---- | ---- |----------- |
| 0x0 - 0x1F_FFFF | 2 MiB| Null Memory | Will throw `NULL MEMORY EXCEPTION` error if accessed |
| 0x20_0000 - 0x9E_8FFF| 8,294,400 bytes |Frame Buffer  |Frame Buffer for the 1920x1080 screen. Each 4-byte pixel is in the form XRGB, where the `X` byte does nothing. Reads are discouraged from this memory.|
| 0x9E_9000 - 0x9F_FFFF|  94,208 bytes | Invalid Memory | Access effects are unknown. |
| 0xA0_0000 - A0_0007| 8 bytes | `poll_keyboard` Procedure Address | Contains the address of the `poll_keyboard` procedure. |
| 0xA0_0008 - A0_000F| 8 bytes | `poll_mouse` Procedure Address | Contains the address of the `poll_mouse` procedure. |
| 0xA0_0010 - A0_0017| 8 bytes | `run_on_core` Procedure Address | Contains the address of the `run_on_core` procedure. |
| 0xA0_0018 - A0_001F| 8 bytes | N_CORES  | Contains the number of physical cores the CPU has (not threads). |
| 0xA0_0020 - A0_0027| 8 bytes | MAX_RAM_ADDRESS  | Contains the highest usable RAM address. `MAX_RAM_ADDRESS.* - 0xC0_0000` will give you the total number of bytes free on the system. |
| 0xA0_0028 - A0_0030| 8 bytes | Program selector entry point  | Entry point of the **Program Selector** program. Run with `A00028R` in the monitor |
| 0xA0_0028 - 0xBF_FFFF | 2,097,120 bytes | Reserved | Reserved for future use.
| 0xC0_0000 - XXXXXX | Depends on the amount of RAM in the machine | Usable Memory | All the free memory on the machine|
| [XXXXXX + 1] - 0xFFFF_FFFF_7FFF_FFFF |  Depends on the amount of RAM in the machine | Invalid Memory| This is left over address space between usable memory and where the monitor lives.
| 0xFFFF_FFFF_8000_0000 and after | Depends on the size of the monitor program | Monitor | Where the monitor lives.  You probably don't want to touch this memory unless you're feeling like a h4xor.| 

## Considerations and Indecisions
There are many things that are up in the air and alternative paths I have considered. It's kind of a delicate balance of keeping the spirit of the original WozMon and trying to provide nicer features.  This includes:
- Should programs run in Ring 3? Or, should I keep the spirit of the Apple I where you can romp all over memory?
    - If programs run at Ring 3, should the procedures and runtime constants be system calls and not part of the memory map?
- Should I support reading and writing 16-bit, 32-bit and 64-bit numbers in the monitor?
- Should I support NVMe SSDs like I do in BoksOS?
- Should I refer "Null Memory" as the "Zero Page" as an homage to the 6502?
- Should Wozmon64 set up the program stack, or should the program be in charge of that?
- Should Wozmon64 programs actually be ELF executables instead of flat binaries?  Flat binaries are appealing since you don't have to parse headers and much more straight forward in understanding how memory is layed out.
- How will sound work? I have not written a sound driver yet. We may have to add to the memory map a couple second audio ring buffer, along with a mirror.
- How will network support work?

## Questions and Feedback
If you have any questions or feedback, I'd love to hear from you! Please reach out to me at dan@boksos.com or DM @dbokser91 on Twitter.